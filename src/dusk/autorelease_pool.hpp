#pragma once

// One Objective-C autorelease pool per frame on the game thread. On Apple Vision Pro
// the game runs on a plain pthread with no run loop, so nothing drains its autoreleased
// objects (Metal command buffers, render pass descriptors and the like, from aurora and
// the OpenXR provider) until the thread exits: memory grows for the whole session.
// These are the calls clang emits for @autoreleasepool, usable from C++.
#if defined(__APPLE__)
extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void* pool);

namespace dusk {
class FrameAutoreleasePool {
public:
    FrameAutoreleasePool() : m_pool(objc_autoreleasePoolPush()) {}
    ~FrameAutoreleasePool() { objc_autoreleasePoolPop(m_pool); }
    FrameAutoreleasePool(const FrameAutoreleasePool&) = delete;
    FrameAutoreleasePool& operator=(const FrameAutoreleasePool&) = delete;

private:
    void* m_pool;
};
}  // namespace dusk
#else
namespace dusk {
struct FrameAutoreleasePool {};
}  // namespace dusk
#endif
