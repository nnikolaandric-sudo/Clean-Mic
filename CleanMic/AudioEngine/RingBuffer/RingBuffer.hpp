#pragma once
// TODO: Faza 1 — Lock-free SPSC Ring Buffer
// Spec: PRD-03-Audio-Engine.md §5
// Zahtjevi: prealociran, lock-free, head/tail atomics, bez malloc u read/write
#include <atomic>
#include <cstddef>

class RingBuffer {
public:
    RingBuffer(size_t capacityFrames);
    ~RingBuffer();
    bool write(const float* data, size_t frames);
    bool read(float* out, size_t frames);
    size_t availableRead() const;
    size_t availableWrite() const;
    void reset();
private:
    float* buffer = nullptr;
    size_t capacity = 0;
    std::atomic<size_t> head{0};
    std::atomic<size_t> tail{0};
};
