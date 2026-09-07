// dear imgui: axmol multi-viewport hooks — Metal renderer path
// Companion to imgui_impl_axmol.cpp. Compiled only when AX_ENABLE_MTL=1 on Apple platforms.
//
// Wires ImGui multi-viewport Renderer_* callbacks to a per-secondary-viewport Metal renderer
// state built on top of upstream imgui_impl_metal.mm (with context-indirection patch), sharing
// the axmol GraphicsDeviceMTL's MTLDevice.
//
// Main viewport stays on the axmol RHI path — this file only handles secondary windows.

#include "imgui.h"
#ifndef IMGUI_DISABLE

#include "imgui_impl_metal.h"

#include "axmol/rhi/metal/GraphicsDeviceMTL.h"
#include "axmol/rhi/metal/TextureMTL.h"
#include "axmol/rhi/metal/UtilsMTL.h"
#include "axmol/rhi/GraphicsCore.h"
#include "axmol/renderer/Texture2D.h"
#include "axmol/base/Object.h"
#include "axmol/platform/PlatformMacros.h"

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

#define GLFW_EXPOSE_NATIVE_COCOA
#include <GLFW/glfw3.h>
#include <GLFW/glfw3native.h>

using namespace ax;

struct ImGui_ImplAxmol_MTL_ViewportData
{
    CAMetalLayer*        Layer;
    id<MTLCommandQueue>  CommandQueue;
    void*                MetalContext;
    NSView*              View;
};

// Texture resolver: axmol Texture2D* (stored in ImTextureID by imgui_impl_axmol) → id<MTLTexture>.
// Unknown / unsupported handles resolve to nil; encoder then binds nil, producing an untextured
// draw rather than a crash.
static id<MTLTexture> ImGui_ImplAxmol_MTL_ResolveTexture(ImTextureID tex_id)
{
    if (tex_id == ImTextureID_Invalid)
        return nil;
    auto obj = reinterpret_cast<ax::Object*>(static_cast<uintptr_t>(tex_id));
    auto tex2d = dynamic_cast<ax::Texture2D*>(obj);
    if (!tex2d)
        return nil;
    auto rhi_tex = tex2d->getRHITexture();
    if (!rhi_tex)
        return nil;
    return static_cast<ax::rhi::mtl::TextureImpl*>(rhi_tex)->internalHandle();
}

static id<MTLDevice> ImGui_ImplAxmol_MTL_GetSharedDevice()
{
    return static_cast<ax::rhi::mtl::GraphicsDeviceImpl*>(axdrv)->getMTLDevice();
}

static CGSize ImGui_ImplAxmol_MTL_ComputeDrawableSize(NSView* view)
{
    const NSRect fbRect = [view convertRectToBacking:[view bounds]];
    return CGSizeMake(fbRect.size.width, fbRect.size.height);
}

static void ImGui_ImplAxmol_MTL_CreateWindow(ImGuiViewport* viewport)
{
    NSWindow* nsWindow = (__bridge NSWindow*)viewport->PlatformHandleRaw;
    if (nsWindow == nil)
    {
        GLFWwindow* glfwWindow = static_cast<GLFWwindow*>(viewport->PlatformHandle);
        if (glfwWindow)
            nsWindow = (__bridge NSWindow*)glfwGetCocoaWindow(glfwWindow);
    }
    IM_ASSERT(nsWindow != nil && "ImGui_ImplAxmol_MTL_CreateWindow: NSWindow unavailable — Platform backend must run first");

    NSView* view = [nsWindow contentView];
    [view setWantsLayer:YES];

    id<MTLDevice> device = ImGui_ImplAxmol_MTL_GetSharedDevice();

    CAMetalLayer* layer      = [CAMetalLayer layer];
    layer.device             = device;
    layer.pixelFormat        = ax::rhi::mtl::UtilsMTL::toMTLPixelFormat(
                                   ax::rhi::mtl::UtilsMTL::getDefaultColorAttachmentPixelFormat());
    layer.framebufferOnly    = YES;
    layer.drawableSize       = ImGui_ImplAxmol_MTL_ComputeDrawableSize(view);
    layer.contentsScale      = [nsWindow backingScaleFactor];
    layer.displaySyncEnabled = NO;
    [view setLayer:layer];

    id<MTLCommandQueue> queue = [device newCommandQueue];

    void* metalCtx = ImGui_ImplMetal_CreateContext(device);
    ImGui_ImplMetal_SetContextTextureResolver(metalCtx, &ImGui_ImplAxmol_MTL_ResolveTexture);

    auto* vd            = new ImGui_ImplAxmol_MTL_ViewportData();
    vd->Layer           = layer;
    vd->CommandQueue    = queue;
    vd->MetalContext    = metalCtx;
    vd->View            = view;
    viewport->RendererUserData = vd;
}

static void ImGui_ImplAxmol_MTL_DestroyWindow(ImGuiViewport* viewport)
{
    auto* vd = static_cast<ImGui_ImplAxmol_MTL_ViewportData*>(viewport->RendererUserData);
    if (!vd)
        return;

    if (vd->MetalContext)
        ImGui_ImplMetal_DestroyContext(vd->MetalContext);

    vd->CommandQueue = nil;

    if (vd->View)
    {
        [vd->View setLayer:nil];
        [vd->View setWantsLayer:NO];
    }
    vd->Layer = nil;
    vd->View  = nil;

    delete vd;
    viewport->RendererUserData = nullptr;
}

static void ImGui_ImplAxmol_MTL_SetWindowSize(ImGuiViewport* viewport, ImVec2 /*size*/)
{
    auto* vd = static_cast<ImGui_ImplAxmol_MTL_ViewportData*>(viewport->RendererUserData);
    if (!vd || !vd->Layer || !vd->View)
        return;
    vd->Layer.drawableSize  = ImGui_ImplAxmol_MTL_ComputeDrawableSize(vd->View);
    vd->Layer.contentsScale = [[vd->View window] backingScaleFactor];
}

static void ImGui_ImplAxmol_MTL_RenderWindow(ImGuiViewport* viewport, void* /*render_arg*/)
{
    auto* vd = static_cast<ImGui_ImplAxmol_MTL_ViewportData*>(viewport->RendererUserData);
    if (!vd || !vd->Layer || !vd->CommandQueue || !vd->MetalContext)
        return;

    @autoreleasepool
    {
        NSWindow* win = [vd->View window];
        if (win)
        {
            const CGFloat scale = [win backingScaleFactor];
            if (vd->Layer.contentsScale != scale)
                vd->Layer.contentsScale = scale;
            const CGSize desired = ImGui_ImplAxmol_MTL_ComputeDrawableSize(vd->View);
            if (!CGSizeEqualToSize(vd->Layer.drawableSize, desired))
                vd->Layer.drawableSize = desired;
        }

        id<CAMetalDrawable> drawable = [vd->Layer nextDrawable];
        if (drawable == nil)
            return; // window minimized / offscreen — skip frame

        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture     = drawable.texture;
        rpd.colorAttachments[0].loadAction  = (viewport->Flags & ImGuiViewportFlags_NoRendererClear)
                                                  ? MTLLoadActionLoad
                                                  : MTLLoadActionClear;
        rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer>         cmd = [vd->CommandQueue commandBuffer];
        id<MTLRenderCommandEncoder>  enc = [cmd renderCommandEncoderWithDescriptor:rpd];

        ImGui_ImplMetal_SetCurrentContext(vd->MetalContext);
        ImGui_ImplMetal_NewFrame(rpd);
        ImGui_ImplMetal_RenderDrawData(viewport->DrawData, cmd, enc);

        [enc endEncoding];
        [cmd presentDrawable:drawable];
        [cmd commit];
    }
}

static void ImGui_ImplAxmol_MTL_SwapBuffers(ImGuiViewport* /*viewport*/, void* /*render_arg*/)
{
    // No-op: presentDrawable + commit in RenderWindow already schedules present.
}

// Public entrypoint (called from imgui_impl_axmol.cpp under #if AX_ENABLE_MTL).
extern "C" void ImGui_ImplAxmol_MTL_InstallViewportHooks(ImGuiPlatformIO& platform_io)
{
    platform_io.Renderer_CreateWindow  = ImGui_ImplAxmol_MTL_CreateWindow;
    platform_io.Renderer_DestroyWindow = ImGui_ImplAxmol_MTL_DestroyWindow;
    platform_io.Renderer_SetWindowSize = ImGui_ImplAxmol_MTL_SetWindowSize;
    platform_io.Renderer_RenderWindow  = ImGui_ImplAxmol_MTL_RenderWindow;
    platform_io.Renderer_SwapBuffers   = ImGui_ImplAxmol_MTL_SwapBuffers;
}

#endif // #ifndef IMGUI_DISABLE
