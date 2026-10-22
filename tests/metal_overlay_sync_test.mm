#include <NoGraphicsAPI/NoGraphicsAPI.hpp>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

namespace
{
struct TestState
{
    gpu::Device* device = nullptr;
    gpu::TimelineSemaphore* gate = nullptr;
    gpu::TimelineSemaphore* rendered = nullptr;
    id<MTL4CommandQueue> overlay_queue = nil;
    id<MTLEvent> overlay_gate = nil;
    id<MTLSharedEvent> overlay_release = nil;
    id<MTLSharedEvent> overlay_completed = nil;
    dispatch_semaphore_t scheduled = nullptr;
    dispatch_semaphore_t presented = nullptr;
    IMP original_present = nullptr;
    IMP original_commit = nullptr;
    id overlay_commands = nil;
    id<CAMetalDrawable> overlay_drawable = nil;
    bool overlay = false;
    bool overlay_on_commit = false;
    bool scheduled_early = false;
    bool presented_early = false;
    uint64 completion_at_present = 0;
    uint32 worker_done = 0;
} test;

void encode_overlay(id commands, id<CAMetalDrawable> drawable)
{
    if (test.overlay)
    {
        [commands encodeWaitForEvent:test.overlay_gate value:1];
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.6, 0.2, 0.4, 1.0);
        [[commands renderCommandEncoderWithDescriptor:pass] endEncoding];
    }
    [commands encodeSignalEvent:test.overlay_completed value:1];
}

void present_hook(id commands, SEL selector, id<CAMetalDrawable> drawable)
{
    if (test.overlay_on_commit)
    {
        test.overlay_commands = commands;
        test.overlay_drawable = drawable;
    }
    else encode_overlay(commands, drawable);
    [commands addScheduledHandler:^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(test.scheduled); }];
    [drawable addPresentedHandler:^(id<MTLDrawable>) {
        test.completion_at_present = test.overlay_completed.signaledValue;
        dispatch_semaphore_signal(test.presented);
    }];
    reinterpret_cast<void (*)(id, SEL, id<CAMetalDrawable>)>(test.original_present)(commands, selector, drawable);
}

void commit_hook(id commands, SEL selector)
{
    if (commands == test.overlay_commands)
    {
        encode_overlay(commands, test.overlay_drawable);
        test.overlay_commands = nil;
    }
    reinterpret_cast<void (*)(id, SEL)>(test.original_commit)(commands, selector);
}

void* release_rendering(void*)
{
    @autoreleasepool
    {
        test.scheduled_early = dispatch_semaphore_wait(test.scheduled, dispatch_time(DISPATCH_TIME_NOW, 1000000000)) == 0;
        test.presented_early = dispatch_semaphore_wait(test.presented, DISPATCH_TIME_NOW) == 0;
        gpu::submit(test.device, {.completion = {.semaphore = test.gate, .value = 1}}, 1);
        gpu::wait_timeline({.semaphore = test.rendered, .value = 1});
        if (test.overlay)
        {
            test.presented_early |= dispatch_semaphore_wait(test.presented, dispatch_time(DISPATCH_TIME_NOW, 100000000)) == 0;
            test.overlay_release.signaledValue = 1;
        }
        __atomic_store_n(&test.worker_done, 1, __ATOMIC_RELEASE);
        return nullptr;
    }
}
}

int main(int argc, char** argv)
{
    for (int i = 1; i < argc; ++i)
    {
        if (strcmp(argv[i], "--overlay") == 0) test.overlay = true;
        else if (strcmp(argv[i], "--overlay-on-commit") == 0) test.overlay = test.overlay_on_commit = true;
        else return 1;
    }
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp finishLaunching];
        NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 320, 180)
            styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        window.title = @"Metal overlay synchronization test";
        [window center];
        CAMetalLayer* layer = [CAMetalLayer new];
        layer.drawableSize = CGSizeMake(320, 180);
        window.contentView.wantsLayer = YES;
        window.contentView.layer = layer;
        const gpu::DeviceInit init = gpu::create_device({.window = layer, .desired_swapchain_image_count = 3,
            .steam_overlay_compatibility = true, .desired_queue_count = 2});
        if (init.error == gpu::Error::unsupported) { [layer release]; return 77; }
        if (!init.device) { [layer release]; return 1; }
        test.device = init.device;
        test.gate = gpu::create_timeline_semaphore(test.device);
        test.rendered = gpu::create_timeline_semaphore(test.device);
        test.overlay_queue = [layer.device newMTL4CommandQueue];
        test.overlay_gate = [layer.device newEvent];
        test.overlay_release = [layer.device newSharedEvent];
        [test.overlay_queue waitForEvent:test.overlay_release value:1];
        [test.overlay_queue signalEvent:test.overlay_gate value:1];
        test.overlay_completed = [layer.device newSharedEvent];
        test.scheduled = dispatch_semaphore_create(0);
        test.presented = dispatch_semaphore_create(0);
        id<MTLCommandQueue> hook_queue = [layer.device newCommandQueue];
        id<MTLCommandBuffer> hook_buffer = [hook_queue commandBuffer];
        Method method = class_getInstanceMethod([hook_buffer class], @selector(presentDrawable:));
        test.original_present = method_setImplementation(method, reinterpret_cast<IMP>(present_hook));
        Method commit_method = class_getInstanceMethod([hook_buffer class], @selector(commit));
        test.original_commit = method_setImplementation(commit_method, reinterpret_cast<IMP>(commit_hook));
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [CATransaction flush];
        const double ready = CACurrentMediaTime() + 0.2;
        while (CACurrentMediaTime() < ready)
        {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
        gpu::CommandPool* pool = gpu::create_command_pool(test.device);
        gpu::CommandBuffer* commands = gpu::begin_commands(pool);
        const gpu::SwapchainFrame target = gpu::acquire(commands);
        if (!target.render_view) return 2;
        gpu::begin_render_pass(commands, {.colors = {{.render_view = target.render_view, .load = gpu::LoadOp::clear,
            .clear = {.x = 0.2f, .y = 0.4f, .z = 0.6f, .w = 1.0f}}}});
        gpu::end_render_pass(commands);
        gpu::end_commands(commands);
        pthread_t worker;
        pthread_create(&worker, nullptr, release_rendering, nullptr);
        gpu::submit_and_present(test.device, {.commands = {commands}, .waits = {{.semaphore = test.gate, .value = 1}},
            .completion = {.semaphore = test.rendered, .value = 1}});
        while (!__atomic_load_n(&test.worker_done, __ATOMIC_ACQUIRE))
        {
            NSEvent* event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]
                inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            [NSApp updateWindows];
        }
        pthread_join(worker, nullptr);
        gpu::wait_idle(test.device);
        const bool presented = test.presented_early ||
            dispatch_semaphore_wait(test.presented, dispatch_time(DISPATCH_TIME_NOW, 1000000000)) == 0;
        const bool valid = test.scheduled_early && presented && !test.presented_early && test.completion_at_present == 1;
        printf("%s: scheduled before rendering=%u, presented=%u, premature presentation=%u, overlay completion at presentation=%llu\n",
            test.overlay_on_commit ? "Commit overlay" : test.overlay ? "Present overlay" : "No overlay",
            test.scheduled_early, presented, test.presented_early, test.completion_at_present);
        method_setImplementation(method, test.original_present);
        method_setImplementation(commit_method, test.original_commit);
        gpu::destroy_command_pool(pool);
        gpu::destroy_timeline_semaphore(test.rendered);
        gpu::destroy_timeline_semaphore(test.gate);
        gpu::destroy_device(test.device);
        test.overlay_release.signaledValue = 1;
        [test.overlay_queue signalEvent:test.overlay_completed value:2];
        [test.overlay_completed waitUntilSignaledValue:2 timeoutMS:1000];
        [hook_queue release]; [test.overlay_queue release]; [test.overlay_gate release]; [test.overlay_completed release];
        [test.overlay_release release];
        dispatch_release(test.scheduled); dispatch_release(test.presented);
        [window close]; [window release];
        [layer release];
        return valid ? 0 : 1;
    }
}
