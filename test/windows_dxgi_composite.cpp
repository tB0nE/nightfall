// Local proof for Vibepollo's planned same-adapter SDR multi-output surface.
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <cstdio>
#include <vector>
#include <algorithm>
#include <chrono>
#include <thread>
using Microsoft::WRL::ComPtr;
#define CHECK(call) do { HRESULT hr = (call); if (FAILED(hr)) { std::fprintf(stderr, "%s: %08lx\n", #call, (unsigned long)hr); return 1; } } while (0)
struct Output {
    DXGI_OUTPUT_DESC desc{};
    ComPtr<IDXGIOutputDuplication> duplication;
    unsigned updates = 0, timeouts = 0;
};
int main() {
    ComPtr<IDXGIFactory1> factory;
    CHECK(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    ComPtr<IDXGIAdapter1> adapter;
    CHECK(factory->EnumAdapters1(0, &adapter));
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    CHECK(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
        nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &context));
    std::vector<Output> outputs;
    RECT bounds{};
    bool first = true;
    for (UINT i = 0;; ++i) {
        ComPtr<IDXGIOutput> output;
        HRESULT enumerated = adapter->EnumOutputs(i, &output);
        if (enumerated == DXGI_ERROR_NOT_FOUND) break;
        CHECK(enumerated);
        Output item;
        CHECK(output->GetDesc(&item.desc));
        if (!item.desc.AttachedToDesktop) continue;
        if (item.desc.Rotation != DXGI_MODE_ROTATION_IDENTITY) {
            std::fprintf(stderr, "Rotated outputs require a rotation pass\n"); return 1;
        }
        ComPtr<IDXGIOutput1> output1;
        CHECK(output.As(&output1));
        CHECK(output1->DuplicateOutput(device.Get(), &item.duplication));
        const RECT r = item.desc.DesktopCoordinates;
        if (first) { bounds = r; first = false; }
        else { bounds.left = std::min(bounds.left,r.left); bounds.top = std::min(bounds.top,r.top);
            bounds.right = std::max(bounds.right,r.right); bounds.bottom = std::max(bounds.bottom,r.bottom); }
        outputs.push_back(std::move(item));
    }
    if (outputs.empty()) return 1;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = bounds.right-bounds.left; desc.Height = bounds.bottom-bounds.top;
    desc.MipLevels = desc.ArraySize = 1; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> surface;
    CHECK(device->CreateTexture2D(&desc,nullptr,&surface));
    ComPtr<ID3D11RenderTargetView> target;
    CHECK(device->CreateRenderTargetView(surface.Get(),nullptr,&target));
    const float black[4] = {0,0,0,1}; context->ClearRenderTargetView(target.Get(),black);
    const auto started = std::chrono::steady_clock::now();
    unsigned ticks = 0;
    std::vector<double> capture_us;
    for (; ticks < 600; ++ticks) {
    const auto tick_start = std::chrono::steady_clock::now();
    for (auto &item : outputs) {
        DXGI_OUTDUPL_FRAME_INFO info{};
        ComPtr<IDXGIResource> resource;
        // An idle monitor must not block updates from the other monitor.
        // Keep its previous pixels in the persistent composite on timeout.
        HRESULT acquired = item.duplication->AcquireNextFrame(item.updates ? 0 : 2000,&info,&resource);
        if (acquired == DXGI_ERROR_WAIT_TIMEOUT) { ++item.timeouts; continue; }
        CHECK(acquired);
        ComPtr<ID3D11Texture2D> image;
        HRESULT queried = resource.As(&image);
        if (FAILED(queried)) { item.duplication->ReleaseFrame(); CHECK(queried); }
        D3D11_TEXTURE2D_DESC source; image->GetDesc(&source);
        if (source.Format != desc.Format || source.Width != (UINT)(item.desc.DesktopCoordinates.right-item.desc.DesktopCoordinates.left) ||
            source.Height != (UINT)(item.desc.DesktopCoordinates.bottom-item.desc.DesktopCoordinates.top)) {
            item.duplication->ReleaseFrame();
            std::fprintf(stderr,"Output format or geometry changed; capture must reinitialize\n"); return 1;
        }
        context->CopySubresourceRegion(surface.Get(),0,
            item.desc.DesktopCoordinates.left-bounds.left,
            item.desc.DesktopCoordinates.top-bounds.top,0,image.Get(),0,nullptr);
        CHECK(item.duplication->ReleaseFrame());
        if (!item.updates) std::printf("captured=%ls offset=%ld,%ld size=%u,%u\n",item.desc.DeviceName,
            item.desc.DesktopCoordinates.left-bounds.left,item.desc.DesktopCoordinates.top-bounds.top,
            source.Width,source.Height);
        ++item.updates;
    }
    context->Flush();
    capture_us.push_back(std::chrono::duration<double,std::micro>(std::chrono::steady_clock::now()-tick_start).count());
    std::this_thread::sleep_until(started + std::chrono::microseconds((ticks+1)*1000000LL/120));
    }
    std::sort(capture_us.begin(),capture_us.end());
    std::printf("Continuous capture ticks=%u elapsed_ms=%.1f submission_us_median=%.1f p95=%.1f\n",ticks,
        std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count(),
        capture_us[capture_us.size()/2],capture_us[capture_us.size()*95/100]);
    for (const auto &item : outputs)
        std::printf("output=%ls updates=%u idle_polls=%u\n",item.desc.DeviceName,item.updates,item.timeouts);
    std::printf("GPU composite submitted: outputs=%zu size=%u,%u\n",outputs.size(),desc.Width,desc.Height);
    // Mapping a staging copy waits for GPU completion and verifies each
    // monitor's destination region, including its desktop offset.
    D3D11_TEXTURE2D_DESC staging_desc = desc;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0; staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    CHECK(device->CreateTexture2D(&staging_desc,nullptr,&staging));
    context->CopyResource(staging.Get(),surface.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    CHECK(context->Map(staging.Get(),0,D3D11_MAP_READ,0,&mapped));
    bool all_nonblack = true;
    for (const auto &item : outputs) {
        const RECT r = item.desc.DesktopCoordinates;
        unsigned long long hash = 14695981039346656037ULL;
        unsigned long long nonblack = 0;
        for (LONG y = r.top; y < r.bottom; ++y) {
            const auto *row = static_cast<const unsigned char *>(mapped.pData) +
                (y-bounds.top)*mapped.RowPitch + (r.left-bounds.left)*4;
            for (LONG x = 0; x < r.right-r.left; ++x) {
                if (row[x*4] || row[x*4+1] || row[x*4+2]) ++nonblack;
                for (int channel = 0; channel < 3; ++channel) {
                    hash ^= row[x*4+channel]; hash *= 1099511628211ULL;
                }
            }
        }
        std::printf("verified=%ls nonblack_pixels=%llu checksum=%016llx\n",
            item.desc.DeviceName,nonblack,hash);
        all_nonblack = all_nonblack && nonblack > 0;
    }
    context->Unmap(staging.Get(),0);
    if (!all_nonblack) {
        std::fprintf(stderr,"A captured monitor is entirely black; inspect before accepting\n"); return 1;
    }
}
