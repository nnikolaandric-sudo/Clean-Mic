#include <CoreAudio/CoreAudio.h>
#include <iostream>
#include <vector>
#include <cmath>
#include <fstream>
#include <atomic>
#include <thread>
#include <chrono>
#include <cstring>

// ===== RingBuffer (lock-free SPSC mock with atomics, simplified from PRD-03 §5) =====
class RingBuffer {
public:
    explicit RingBuffer(size_t capacityFrames) {
        size_t pow2 = 1;
        while (pow2 < capacityFrames) pow2 <<= 1;
        capacity = pow2;
        buffer = new float[capacity]();
    }
    ~RingBuffer() { delete[] buffer; }
    bool write(const float* data, size_t frames) {
        size_t h = head.load(std::memory_order_relaxed);
        size_t t = tail.load(std::memory_order_acquire);
        size_t avail = capacity - (h - t);
        if (frames > avail) { overruns++; return false; }
        for (size_t i=0;i<frames;i++) buffer[(h+i) & (capacity-1)] = data[i];
        head.store(h+frames, std::memory_order_release);
        return true;
    }
    bool read(float* out, size_t frames) {
        size_t t = tail.load(std::memory_order_relaxed);
        size_t h = head.load(std::memory_order_acquire);
        size_t avail = h - t;
        if (frames > avail) { underruns++; return false; }
        for (size_t i=0;i<frames;i++) out[i] = buffer[(t+i) & (capacity-1)];
        tail.store(t+frames, std::memory_order_release);
        return true;
    }
    size_t availableRead() const {
        return head.load(std::memory_order_acquire) - tail.load(std::memory_order_acquire);
    }
    size_t availableWrite() const { return capacity - availableRead(); }
    void reset() { head.store(0); tail.store(0); overruns=0; underruns=0; }
    size_t overruns=0, underruns=0;
private:
    float* buffer=nullptr;
    size_t capacity=0;
    std::atomic<size_t> head{0}, tail{0};
};

// ===== Mock NoiseProcessor (PRD-03 §6) =====
enum class CleanMicMode { Light=0, Balanced=1, Maximum=2 };
class NoiseProcessor {
public:
    static const int frameSize = 480;
    explicit NoiseProcessor(CleanMicMode m=CleanMicMode::Balanced): mode(m) {}
    void setMode(CleanMicMode m){ mode=m; }
    float strength() const {
        if(mode==CleanMicMode::Light) return 0.3f;
        if(mode==CleanMicMode::Balanced) return 0.6f;
        return 0.9f;
    }
    float gateThresh() const {
        if(mode==CleanMicMode::Light) return 0.15f;
        if(mode==CleanMicMode::Balanced) return 0.30f;
        return 0.45f;
    }
    // returns VAD 0..1
    float processFrame(float* out, const float* in) {
        float energy=0;
        for(int i=0;i<frameSize;i++) energy += in[i]*in[i];
        energy = sqrtf(energy/frameSize);
        float vad = std::min(1.0f, energy*20.0f);
        float str = strength();
        float thr = gateThresh();
        for(int i=0;i<frameSize;i++){
            dc = 0.995f*dc + 0.005f*in[i];
            float hp = in[i] - dc;
            float v = hp;
            if(vad < thr*0.5f) v*=0.15f;
            else {
                float att = 1.0f - str*0.25f;
                if(vad < thr) att = 1.0f - str*0.9f;
                v *= (1.0f - (1.0f-att)*(1.0f-vad));
            }
            if(fabsf(v)>0.9f) v = (v>0?1:-1)*(0.9f + (fabsf(v)-0.9f)/(1+fabsf(v)-0.9f));
            out[i]=v;
        }
        return vad;
    }
private:
    CleanMicMode mode;
    float dc=0;
};

// ===== WAV Writer (16-bit PCM) =====
void writeWAV(const std::string& path, const std::vector<float>& samples, int sampleRate=48000){
    std::ofstream f(path, std::ios::binary);
    int32_t dataSize = samples.size()*2;
    int32_t fileSize = 36 + dataSize;
    // RIFF
    f.write("RIFF",4);
    f.write((char*)&fileSize,4);
    f.write("WAVE",4);
    f.write("fmt ",4);
    int32_t fmtSize=16; f.write((char*)&fmtSize,4);
    int16_t audioFormat=1; f.write((char*)&audioFormat,2);
    int16_t channels=1; f.write((char*)&channels,2);
    int32_t sr=sampleRate; f.write((char*)&sr,4);
    int32_t byteRate=sampleRate*2; f.write((char*)&byteRate,4);
    int16_t blockAlign=2; f.write((char*)&blockAlign,2);
    int16_t bits=16; f.write((char*)&bits,2);
    f.write("data",4);
    f.write((char*)&dataSize,4);
    for(float s: samples){
        float c = std::max(-1.0f, std::min(1.0f, s));
        int16_t v = int16_t(c*32767);
        f.write((char*)&v,2);
    }
    std::cout << "  📝 WAV: " << path << " (" << samples.size() << " samples, " << (samples.size()/(float)sampleRate) << "s)\n";
}

// ===== Device Lister (CoreAudio C) =====
std::string cfStringToStd(CFStringRef cf){
    if(!cf) return "-";
    char buf[512]; CFStringGetCString(cf, buf, sizeof(buf), kCFStringEncodingUTF8);
    return std::string(buf);
}
void listDevices(){
    std::cout << "🎙  CleanMic — Input Devices (CoreAudio C)\n";
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size=0; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr,0,nullptr,&size);
    int count = size / sizeof(AudioDeviceID);
    std::vector<AudioDeviceID> ids(count);
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&addr,0,nullptr,&size,ids.data());
    AudioDeviceID defaultID=0; UInt32 ds=sizeof(defaultID);
    AudioObjectPropertyAddress defAddr={kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&defAddr,0,nullptr,&ds,&defaultID);
    int inputCount=0;
    for(auto id: ids){
        // check input channels
        AudioObjectPropertyAddress cfgAddr={kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
        UInt32 cfgSize=0; if(AudioObjectGetPropertyDataSize(id,&cfgAddr,0,nullptr,&cfgSize)!=noErr) continue;
        std::vector<char> buf(cfgSize);
        AudioBufferList* bl = (AudioBufferList*)buf.data();
        if(AudioObjectGetPropertyData(id,&cfgAddr,0,nullptr,&cfgSize,bl)!=noErr) continue;
        AudioBufferList* abl = bl;
        uint32_t ch=0; for(UInt32 i=0;i<abl->mNumberBuffers;i++) ch += abl->mBuffers[i].mNumberChannels;
        if(ch==0) continue;
        inputCount++;
        // name
        CFStringRef nameCF=nullptr; UInt32 ns=sizeof(nameCF);
        AudioObjectPropertyAddress nameAddr={kAudioDevicePropertyDeviceNameCFString, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(id,&nameAddr,0,nullptr,&ns,&nameCF);
        std::string name = cfStringToStd(nameCF);
        if(nameCF) CFRelease(nameCF);
        // uid
        CFStringRef uidCF=nullptr; ns=sizeof(uidCF);
        AudioObjectPropertyAddress uidAddr={kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(id,&uidAddr,0,nullptr,&ns,&uidCF);
        std::string uid = cfStringToStd(uidCF);
        if(uidCF) CFRelease(uidCF);
        // sample rate
        double sr=0; UInt32 srs=sizeof(sr);
        AudioObjectPropertyAddress srAddr={kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectGetPropertyData(id,&srAddr,0,nullptr,&srs,&sr);
        std::string def = (id==defaultID?" [DEFAULT]":"");
        std::cout << "  " << inputCount << ". " << name << " — id:" << id << " " << ch << "ch @" << (int)sr << "Hz" << def << " uid:" << uid << "\n";
        if(nameCF) {}
    }
    std::cout << "   Ukupno input: " << inputCount << "/" << count << " uređaja\n";
    std::cout << "   Default ID: " << defaultID << "\n";
}

// ===== Test RingBuffer =====
void testRings(){
    std::cout << "\n🧪 RingBuffer stress test — 2 threada, 2s\n";
    RingBuffer ring(16384);
    const int framesPerWrite=512;
    const int iterations=5000;
    std::atomic<int> writes{0}, reads{0};
    std::thread prod([&](){
        std::vector<float> data(framesPerWrite,0.5f);
        for(int i=0;i<iterations;i++){
            data[0]= (i%100)/100.0f;
            while(!ring.write(data.data(), framesPerWrite)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
            writes++;
        }
    });
    std::thread cons([&](){
        std::vector<float> out(framesPerWrite);
        int r=0;
        while(r<iterations){
            if(ring.read(out.data(), framesPerWrite)){ r++; reads=r; }
            else std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    });
    prod.join(); cons.join();
    std::cout << "✅ writes=" << writes << " reads=" << reads << " overruns=" << ring.overruns << " underruns=" << ring.underruns << "\n";
    if(ring.overruns==0 && ring.underruns==0) std::cout << "   ✅ PASS — nema over/underrun\n";
    else std::cout << "   ⚠️  Over/underrun prisutni (jitter) — očekivano na load-u\n";
}

// ===== Offline process synthetic =====
void offlineDemo(){
    std::cout << "\n🔄 Offline process demo (synthetic 440Hz + noise)\n";
    const double sr=48000;
    const double dur=2.0;
    const int total = int(sr*dur);
    std::vector<float> in(total);
    for(int i=0;i<total;i++){
        double t = i/sr;
        float sine = 0.4f * sin(2*M_PI*440*t);
        float noise = 0.15f * sin(2*M_PI*1200*t) * (i%480<240?1:0.3f); // mock ventilator
        float burst = (i> sr*0.5 && i< sr*0.6) ? 0.5f*sin(2*M_PI*3000*t) : 0; // transient noise
        in[i]= sine + noise + burst;
    }
    writeWAV("/tmp/cleanmic_synthetic_in.wav", in, 48000);
    std::cout << "   Input SNR mock: sine 440Hz + ventilator\n";

    for(auto mode: {CleanMicMode::Light, CleanMicMode::Balanced, CleanMicMode::Maximum}){
        std::string name = mode==CleanMicMode::Light?"Light":mode==CleanMicMode::Balanced?"Balanced":"Maximum";
        NoiseProcessor proc(mode);
        std::vector<float> out; out.reserve(total);
        float maxVad=0, avgMs=0; auto t0=std::chrono::high_resolution_clock::now();
        for(int i=0;i<total;i+=480){
            float outFrame[480]={0};
            float inFrame[480]={0};
            for(int j=0;j<480;j++) inFrame[j]= (i+j<total? in[i+j]:0);
            auto ft0=std::chrono::high_resolution_clock::now();
            float vad = proc.processFrame(outFrame, inFrame);
            auto ft1=std::chrono::high_resolution_clock::now();
            double ms = std::chrono::duration<double, std::milli>(ft1-ft0).count();
            avgMs+=ms; maxVad=std::max(maxVad, vad);
            for(int j=0;j<480 && i+j<total;j++) out.push_back(outFrame[j]);
        }
        auto t1=std::chrono::high_resolution_clock::now();
        double totalMs = std::chrono::duration<double, std::milli>(t1-t0).count();
        std::cout << "   [" << name << "] frames=" << (total/480) << " total=" << totalMs << "ms avg=" << (totalMs/(total/480)) << "ms maxVad=" << maxVad << "\n";
        std::string path = std::string("/tmp/cleanmic_synthetic_")+name+".wav";
        writeWAV(path, out, 48000);
        std::cout << "   ▶️  afplay \"" << path << "\"\n";
    }
    std::cout << "\n✅ AB test: afplay /tmp/cleanmic_synthetic_in.wav vs afplay /tmp/cleanmic_synthetic_Balanced.wav\n";
}

// ===== Real-time mock via Rings =====
void realtimeMock(){
    std::cout << "\n⚡ Real-time mock: InputRing -> Processing Worker -> OutputRing (2s)\n";
    RingBuffer inRing(16384), outRing(131072); // large enough to avoid deadlock
    NoiseProcessor proc(CleanMicMode::Balanced);
    std::atomic<bool> running{true};
    std::atomic<int> framesProc{0};
    double totalMs=0, maxMs=0;

    // worker
    std::thread worker([&](){
        float inF[480], outF[480];
        while(running || inRing.availableRead()>=480){
            if(inRing.availableRead()<480){ std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue; }
            if(outRing.availableWrite()<480){ std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue; }
            inRing.read(inF,480);
            auto t0=std::chrono::high_resolution_clock::now();
            proc.processFrame(outF,inF);
            auto t1=std::chrono::high_resolution_clock::now();
            double ms=std::chrono::duration<double,std::milli>(t1-t0).count();
            totalMs+=ms; if(ms>maxMs) maxMs=ms;
            outRing.write(outF,480);
            framesProc++;
        }
    });

    // feeder: 5 sec of sine at 48k
    int totalFrames = 48000*2;
    int fed=0;
    auto start=std::chrono::high_resolution_clock::now();
    while(fed < totalFrames){
        float chunk[512];
        for(int i=0;i<512;i++){ chunk[i]= 0.3f*sin(2*M_PI*300*(fed+i)/48000.0); }
        while(!inRing.write(chunk,512)) std::this_thread::sleep_for(std::chrono::milliseconds(1));
        fed+=512;
        std::this_thread::sleep_for(std::chrono::milliseconds(10)); // ~real time
        if(fed % 4800 ==0) std::cout << "  fed " << fed << "/" << totalFrames << " inRing " << inRing.availableRead() << " outRing " << outRing.availableRead() << " proc " << framesProc.load() << "\r" << std::flush;
    }
    std::cout << "\n  feeder done, draining...\n";
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    running=false;
    worker.join();
    auto end=std::chrono::high_resolution_clock::now();
    double wallMs=std::chrono::duration<double,std::milli>(end-start).count();
    std::cout << "✅ frames=" << framesProc << " wall=" << wallMs << "ms avgProc=" << (totalMs/framesProc) << "ms maxProc=" << maxMs << "ms\n";
    std::cout << "   in overruns=" << inRing.overruns << " out underruns=" << outRing.underruns << "\n";
    // drain to wav
    std::vector<float> outSamples;
    outSamples.reserve(outRing.availableRead());
    float tmp[480];
    while(outRing.availableRead()>=480){ outRing.read(tmp,480); for(int i=0;i<480;i++) outSamples.push_back(tmp[i]); }
    writeWAV("/tmp/cleanmic_realtime_mock.wav", outSamples, 48000);
}

void printUsage(){
    std::cout << "CleanMic C++ Demo — lokalno pokretljiv bez Xcode (clang++ only)\n\n";
    std::cout << "KORIŠTENJE:\n  ./cleanmic-demo list\n  ./cleanmic-demo test-rings\n  ./cleanmic-demo offline\n  ./cleanmic-demo realtime\n  ./cleanmic-demo all\n\n";
}

int main(int argc, char* argv[]){
    std::string cmd = argc>1? argv[1]:"all";
    if(cmd=="help"||cmd=="--help"||cmd=="-h"){ printUsage(); return 0; }
    std::cout << "CleanMic C++ Demo — Faza 0 Spike (clang++ build)\n";
    std::cout << "SDK: macOS " << __VERSION__ << " | " << __clang_version__ << "\n\n";
    if(cmd=="list"||cmd=="all") listDevices();
    if(cmd=="test-rings"||cmd=="all") testRings();
    if(cmd=="offline"||cmd=="all") offlineDemo();
    if(cmd=="realtime"||cmd=="all") realtimeMock();
    if(cmd=="all"){
        std::cout << "\n🎉 Demo gotov! Fajlovi u /tmp/cleanmic_*.wav — probaj:\n";
        std::cout << "   afplay /tmp/cleanmic_synthetic_in.wav\n";
        std::cout << "   afplay /tmp/cleanmic_synthetic_Balanced.wav\n";
        std::cout << "   afplay /tmp/cleanmic_realtime_mock.wav\n";
        std::cout << "\n💡 Swift CLI (cleanmic-cli) je spreman u Sources/ — za build treba Xcode:\n";
        std::cout << "   xcode-select --install  # ako nema Xcode\n";
        std::cout << "   swift run cleanmic-cli list  (iz CleanMic/)\n";
    }
    return 0;
}
