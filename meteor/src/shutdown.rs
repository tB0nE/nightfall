//! Process-exit requests are separate from async service cleanup.
use tokio::sync::watch;

pub(crate) struct Shutdown(watch::Sender<bool>);
impl Shutdown {
    pub(crate) fn new() -> Self { Self(watch::channel(false).0) }
    pub(crate) fn request(&self) { self.0.send_replace(true); }
    pub(crate) fn subscribe(&self) -> watch::Receiver<bool> { self.0.subscribe() }
    pub(crate) async fn requested(&self) {
        let mut receiver = self.subscribe();
        while !*receiver.borrow_and_update() {
            if receiver.changed().await.is_err() { break; }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn requests_are_sticky_and_repeatable() {
        let shutdown = Shutdown::new();
        shutdown.request();
        shutdown.request();
        tokio::time::timeout(std::time::Duration::from_secs(1), shutdown.requested()).await.unwrap();
        assert!(*shutdown.subscribe().borrow());
    }
    #[tokio::test]
    async fn request_wakes_waiter() {
        let shutdown = std::sync::Arc::new(Shutdown::new());
        let waiter = shutdown.clone();
        let task = tokio::spawn(async move { waiter.requested().await });
        tokio::task::yield_now().await;
        shutdown.request();
        tokio::time::timeout(std::time::Duration::from_secs(1), task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn coordinator_drains_xr_without_closing_other_listener() {
        use tokio::{io::AsyncReadExt, net::{TcpListener, TcpStream}};
        let unrelated = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let unrelated_address = unrelated.local_addr().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let shutdown = Shutdown::new();
        let service = tokio::spawn(crate::xr_control::serve(listener, crate::xr_control::ServiceConfig {
            key: std::sync::Arc::new(crate::crypto::MeteorKey::from_seed([1; 32])),
            allowed: crate::crypto::MeteorKey::from_seed([2; 32]).public,
            enable_relay: true,
            runtime_root: None,
        }, shutdown.subscribe()));
        let mut client = TcpStream::connect(address).await.unwrap();
        let mut greeting = [0; 8];
        tokio::time::timeout(std::time::Duration::from_secs(1), client.read_exact(&mut greeting)).await.unwrap().unwrap();
        shutdown.request();
        tokio::time::timeout(std::time::Duration::from_secs(1), service).await.unwrap().unwrap().unwrap();
        drop(TcpListener::bind(address).await.unwrap());
        // This stands in for an independently owned proxy/discovery listener:
        // XR shutdown must not terminate its task or close its socket.
        let connection = TcpStream::connect(unrelated_address).await.unwrap();
        let (_accepted, _) = unrelated.accept().await.unwrap();
        drop(connection);
    }
}
