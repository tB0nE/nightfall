use std::io;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};

use socket2::{Domain, Protocol, SockAddr, Socket, Type};
use tokio::net::{TcpListener, UdpSocket};

fn dual_stack_socket(ty: Type, protocol: Protocol, port: u16) -> io::Result<Socket> {
    let socket = Socket::new(Domain::IPV6, ty, Some(protocol))?;
    socket.set_only_v6(false)?;
    socket.set_reuse_address(true)?;
    socket.bind(&SockAddr::from(SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port)))?;
    Ok(socket)
}

pub async fn tcp_listener(port: u16) -> io::Result<TcpListener> {
    let socket = dual_stack_socket(Type::STREAM, Protocol::TCP, port)?;
    socket.listen(128)?;
    socket.set_nonblocking(true)?;
    TcpListener::from_std(socket.into())
}

pub async fn udp_socket(port: u16) -> io::Result<UdpSocket> {
    let socket = dual_stack_socket(Type::DGRAM, Protocol::UDP, port)?;
    socket.set_nonblocking(true)?;
    UdpSocket::from_std(socket.into())
}

pub fn tcp_listener_std(port: u16) -> io::Result<std::net::TcpListener> {
    let socket = dual_stack_socket(Type::STREAM, Protocol::TCP, port)?;
    socket.listen(128)?;
    socket.set_nonblocking(false)?;
    Ok(socket.into())
}
