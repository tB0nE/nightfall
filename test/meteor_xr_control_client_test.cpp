// Linux-only cross-language protocol test. Fixed seeds are TEST fixtures only.
#include "network/meteor_cipher.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#include <cassert>
#include <cstring>
#include <iostream>
#include <regex>
#include <vector>

static void transfer(int fd, uint8_t *data, size_t n, bool sending) {
    while(n) {
        auto done=sending ? send(fd,data,n,MSG_NOSIGNAL) : recv(fd,data,n,0);
        assert(done>0);data+=done;n-=done;
    }
}

int main(int argc,char **argv) {
    assert(argc==2);
    uint8_t server_seed[32],client_seed[32],pin[32];
    memset(server_seed,1,32);memset(client_seed,2,32);
    assert(godot::MeteorCipher::identity_public(server_seed,pin));
    // Preserve the existing text KDF API exactly.
    godot::MeteorCipher old_api,new_api;
    assert(old_api.init(pin,"legacy-depth-test",client_seed).empty());
    const std::string old_info="legacy-depth-test";
    assert(new_api.init_bytes(pin,reinterpret_cast<const uint8_t *>(old_info.data()),old_info.size(),client_seed).empty());
    uint8_t old_body[19]={1,2,3},new_body[19]={1,2,3},aad[4]={19,0,0,0};
    assert(old_api.seal(0,aad,4,old_body,3)&&new_api.seal(0,aad,4,new_body,3));
    assert(memcmp(old_body,new_body,19)==0);

    int fd=socket(AF_INET,SOCK_STREAM,0);assert(fd>=0);
    timeval timeout{3,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(std::stoi(argv[1]));
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);assert(connect(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address))==0);
    uint8_t hello[72];transfer(fd,hello,72,false);
    const uint8_t magic[8]={'N','F','X','C',1,0,0,0};
    assert(memcmp(hello,magic,8)==0&&memcmp(hello+8,pin,32)==0);
    uint8_t client_nonce[32];memset(client_nonce,7,32);
    auto context=[&](const char *direction){
        std::string info=std::string("nightfall-xr-control-v1/")+direction;
        info.append(reinterpret_cast<const char *>(hello+40),32);
        info.append(reinterpret_cast<const char *>(client_nonce),32);return info;
    };
    godot::MeteorCipher tx,rx;
    auto c2s=context("client-to-server"),s2c=context("server-to-client");
    assert(tx.init_bytes(pin,reinterpret_cast<const uint8_t *>(c2s.data()),c2s.size(),client_seed).empty());
    assert(rx.init_bytes(pin,reinterpret_cast<const uint8_t *>(s2c.data()),s2c.size(),client_seed).empty());
    uint8_t response[64];memcpy(response,tx.public_key(),32);memcpy(response+32,client_nonce,32);
    transfer(fd,response,64,true);
    uint64_t counter=0;
    auto request=[&](std::string plain){
        uint32_t length=plain.size()+16;assert(length<=4096);
        uint8_t header[4];for(int i=0;i<4;++i)header[i]=(length>>(i*8))&255;
        std::vector<uint8_t> body(length);memcpy(body.data(),plain.data(),plain.size());
        assert(tx.seal(counter,header,4,body.data(),plain.size()));
        transfer(fd,header,4,true);transfer(fd,body.data(),body.size(),true);
        transfer(fd,header,4,false);length=0;for(int i=0;i<4;++i)length|=uint32_t(header[i])<<(i*8);
        assert(length>=16&&length<=4096);body.resize(length);transfer(fd,body.data(),length,false);
        assert(rx.open(counter++,header,4,body.data(),body.size()));
        return std::string(reinterpret_cast<char *>(body.data()),body.size()-16);
    };
    assert(request(R"({"type":"authenticate"})").find("\"state\":\"idle\"")!=std::string::npos);
    auto offer=request(R"({"type":"offer","width":512,"height":512,"hz":20})");
    assert(offer.find("awaiting_acceptance")!=std::string::npos);
    std::smatch match;assert(std::regex_search(offer,match,std::regex("\"session\":\"([0-9a-f]+)\"")));
    auto id=match[1].str();
    auto accepted=request("{\"type\":\"accept\",\"session\":\""+id+"\"}");
    assert(accepted.find("prepared")!=std::string::npos&&accepted.find("\"lan_video_available\":false")!=std::string::npos);
    assert(request("{\"type\":\"stop\",\"session\":\""+id+"\"}").find("\"state\":\"idle\"")!=std::string::npos);
    close(fd);std::cout<<"PASS OpenSSL client / Rust server handshake, offer, accept, stop; legacy KDF unchanged\n";
}
