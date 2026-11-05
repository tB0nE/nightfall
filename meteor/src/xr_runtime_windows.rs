//! Native Windows process ownership for a locally configured XR runtime.
//! Does not change the system OpenXR registration or launch an app by name.
use std::{io, os::windows::io::AsRawHandle, process::{Child, Command}};
use windows_sys::Win32::{Foundation::{CloseHandle,HANDLE},System::JobObjects::{
    CreateJobObjectW,SetInformationJobObject,AssignProcessToJobObject,
    JobObjectExtendedLimitInformation,JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    QueryInformationJobObject,JobObjectBasicAccountingInformation,JOBOBJECT_BASIC_ACCOUNTING_INFORMATION,
    IsProcessInJob,
}};

pub(crate) fn steamvr_running()->io::Result<bool> {
    use windows_sys::Win32::{Foundation::INVALID_HANDLE_VALUE,System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot,TH32CS_SNAPPROCESS,PROCESSENTRY32W,Process32FirstW,Process32NextW}};
    let snapshot=unsafe {CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)};
    if snapshot==INVALID_HANDLE_VALUE {return Err(io::Error::last_os_error());}
    let mut entry:PROCESSENTRY32W=unsafe {std::mem::zeroed()};entry.dwSize=std::mem::size_of_val(&entry) as u32;
    let mut next=unsafe {Process32FirstW(snapshot,&mut entry)};let mut found=false;
    while next!=0 {
        let end=entry.szExeFile.iter().position(|&c|c==0).unwrap_or(entry.szExeFile.len());
        if String::from_utf16_lossy(&entry.szExeFile[..end]).eq_ignore_ascii_case("vrserver.exe") {found=true;break;}
        next=unsafe {Process32NextW(snapshot,&mut entry)};
    }
    unsafe {CloseHandle(snapshot);}Ok(found)
}

fn shutdown_owned_steamvr(job:HANDLE) {
    use windows_sys::Win32::{Foundation::INVALID_HANDLE_VALUE,System::{
        Diagnostics::ToolHelp::{CreateToolhelp32Snapshot,TH32CS_SNAPPROCESS,PROCESSENTRY32W,Process32FirstW,Process32NextW},
        Threading::{OpenProcess,PROCESS_QUERY_LIMITED_INFORMATION,PROCESS_SYNCHRONIZE,WaitForSingleObject},
    },UI::WindowsAndMessaging::{EnumWindows,GetWindowThreadProcessId,PostMessageW,WM_CLOSE}};
    struct Windows {monitors:Vec<u32>,requested:bool}
    unsafe extern "system" fn close_monitor(window:windows_sys::Win32::Foundation::HWND,param:isize)->i32 {
        let windows=unsafe {&mut *(param as *mut Windows)};let mut pid=0;
        unsafe {GetWindowThreadProcessId(window,&mut pid);}
        if windows.monitors.contains(&pid) && unsafe {PostMessageW(window,WM_CLOSE,0,0)}!=0 {windows.requested=true;}
        1
    }
    let snapshot=unsafe {CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0)};
    if snapshot==INVALID_HANDLE_VALUE {return;}
    let mut processes=Vec::new();let mut windows=Windows {monitors:Vec::new(),requested:false};
    let mut entry:PROCESSENTRY32W=unsafe {std::mem::zeroed()};entry.dwSize=std::mem::size_of_val(&entry) as u32;
    let mut next=unsafe {Process32FirstW(snapshot,&mut entry)};
    while next!=0 {
        let end=entry.szExeFile.iter().position(|&c|c==0).unwrap_or(entry.szExeFile.len());
        let name=String::from_utf16_lossy(&entry.szExeFile[..end]).to_ascii_lowercase();
        if matches!(name.as_str(),"vrmonitor.exe"|"vrserver.exe"|"vrcompositor.exe") {
            let handle=unsafe {OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|PROCESS_SYNCHRONIZE,0,entry.th32ProcessID)};
            if !handle.is_null() {
                let mut owned=0;
                if unsafe {IsProcessInJob(handle,job,&mut owned)}!=0 && owned!=0 {
                    if name=="vrmonitor.exe" {windows.monitors.push(entry.th32ProcessID);}
                    processes.push(handle);
                }else {unsafe {CloseHandle(handle);}}
            }
        }
        next=unsafe {Process32NextW(snapshot,&mut entry)};
    }
    unsafe {CloseHandle(snapshot);}
    if !windows.monitors.is_empty() {
        unsafe {EnumWindows(Some(close_monitor),(&mut windows as *mut Windows) as isize);}
    }
    if windows.requested {
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(4);
        while processes.iter().any(|&p|unsafe {WaitForSingleObject(p,0)}!=0) && std::time::Instant::now()<deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        if processes.iter().all(|&p|unsafe {WaitForSingleObject(p,0)}==0) {log::info!("Owned SteamVR shutdown completed normally");}
        else {log::warn!("Owned SteamVR did not close within four seconds; applying job cleanup");}
    }
    for handle in processes {unsafe {CloseHandle(handle);}}
}
fn spawn_owned(command:&mut Command,job:HANDLE)->io::Result<Child> {
    use std::os::windows::process::CommandExt;
    use windows_sys::Win32::{Foundation::INVALID_HANDLE_VALUE,System::{
        Threading::{CREATE_SUSPENDED,CREATE_NO_WINDOW,OpenThread,ResumeThread,THREAD_SUSPEND_RESUME},
        Diagnostics::ToolHelp::{CreateToolhelp32Snapshot,TH32CS_SNAPTHREAD,THREADENTRY32,Thread32First,Thread32Next},
    }};
    // Assign ownership before any launcher code can create descendants.
    let mut child=command.creation_flags(CREATE_SUSPENDED|CREATE_NO_WINDOW).spawn()?;
    let result=(|| {
        if unsafe {AssignProcessToJobObject(job,child.as_raw_handle() as HANDLE)}==0 {return Err(io::Error::last_os_error());}
        let snapshot=unsafe {CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,0)};
        if snapshot==INVALID_HANDLE_VALUE {return Err(io::Error::last_os_error());}
        let mut entry:THREADENTRY32=unsafe {std::mem::zeroed()};entry.dwSize=std::mem::size_of_val(&entry) as u32;
        let mut found=false;let mut resumed=Err(io::Error::other("Suspended XR child has no initial thread"));
        let mut next=unsafe {Thread32First(snapshot,&mut entry)};
        while next!=0 {
            if entry.th32OwnerProcessID==child.id() {
                found=true;
                let thread=unsafe {OpenThread(THREAD_SUSPEND_RESUME,0,entry.th32ThreadID)};
                if thread.is_null() {resumed=Err(io::Error::last_os_error());}
                else {
                    let count=unsafe {ResumeThread(thread)};
                    resumed=if count==u32::MAX {Err(io::Error::last_os_error())}else{Ok(())};
                    unsafe {CloseHandle(thread);}
                }
                break;
            }
            next=unsafe {Thread32Next(snapshot,&mut entry)};
        }
        unsafe {CloseHandle(snapshot);}
        debug_assert!(found || resumed.is_err());resumed
    })();
    if let Err(error)=result {let _=child.kill();let _=child.wait();return Err(error);}
    Ok(child)
}

pub(crate) struct Session {
    job: HANDLE,
    application_job: HANDLE,
    service: Child,
    application: Option<Child>,
}
impl Session {
    #[cfg(test)]
    pub(crate) fn runtime_job_alive(&self)->bool {
        let mut info:JOBOBJECT_BASIC_ACCOUNTING_INFORMATION=unsafe {std::mem::zeroed()};
        unsafe {QueryInformationJobObject(self.job,JobObjectBasicAccountingInformation,
            (&mut info as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),std::mem::size_of_val(&info) as u32,std::ptr::null_mut())!=0 && info.ActiveProcesses>0}
    }
    pub(crate) fn ensure_runtime_running(&mut self)->io::Result<()> {
        if self.service.try_wait()?.is_some() {return Err(io::Error::other("XR runtime exited before Steam launch"));}
        Ok(())
    }
    pub(crate) fn process_ids(&self)->(u32,Option<u32>) {
        (self.service.id(),self.application.as_ref().map(Child::id))
    }
    /// Own the service before accepting an application. Failure leaves no child.
    pub(crate) fn start(command: &mut Command) -> io::Result<Self> {
        let job = unsafe { CreateJobObjectW(std::ptr::null(),std::ptr::null()) };
        if job.is_null() { return Err(io::Error::last_os_error()); }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if unsafe { SetInformationJobObject(job,JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&limits) as u32) } == 0 {
            let error=io::Error::last_os_error(); unsafe { CloseHandle(job); } return Err(error);
        }
        let mut service=match spawn_owned(command,job) {
            Ok(child)=>child,
            Err(error)=>{unsafe { CloseHandle(job); } return Err(error);},
        };
        // Keep application descendants separate from runtime helper processes.
        // SteamVR has persistent compositor/dashboard children of its own.
        let application_job=unsafe { CreateJobObjectW(std::ptr::null(),std::ptr::null()) };
        if application_job.is_null() || unsafe {SetInformationJobObject(application_job,JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),std::mem::size_of_val(&limits) as u32)}==0 {
            let error=io::Error::last_os_error();
            unsafe {CloseHandle(job);if !application_job.is_null() {CloseHandle(application_job);}}
            let _=service.wait();return Err(error);
        }
        Ok(Self {job,application_job,service,application:None})
    }
    pub(crate) fn launch(&mut self,command:&mut Command) -> io::Result<()> {
        if self.application.is_some() {return Err(io::Error::other("XR application already launched"));}
        if self.service.try_wait()?.is_some() {return Err(io::Error::other("XR runtime exited before application launch"));}
        let child=spawn_owned(command,self.application_job)?;
        self.application=Some(child); Ok(())
    }
    pub(crate) fn poll_session(&mut self,external:bool) -> io::Result<Option<std::process::ExitStatus>> {
        if external {self.ensure_runtime_running()?;Ok(None)}else{self.poll()}
    }
    pub(crate) fn poll(&mut self) -> io::Result<Option<std::process::ExitStatus>> {
        if self.service.try_wait()?.is_some() {return Err(io::Error::other("XR runtime exited during session"));}
        let status=self.application.as_mut().ok_or_else(||io::Error::other("XR application not launched"))?.try_wait()?;
        if status.is_some() {
            // Steam/EAC bootstrap processes can exit while their game remains
            // in the application job. Runtime helpers belong to a separate job.
            let mut accounting:JOBOBJECT_BASIC_ACCOUNTING_INFORMATION=unsafe {std::mem::zeroed()};
            if unsafe {QueryInformationJobObject(self.application_job,JobObjectBasicAccountingInformation,
                (&mut accounting as *mut JOBOBJECT_BASIC_ACCOUNTING_INFORMATION).cast(),
                std::mem::size_of_val(&accounting) as u32,std::ptr::null_mut())}==0 {
                return Err(io::Error::last_os_error());
            }
            if accounting.ActiveProcesses>0 {return Ok(None);}
        }
        Ok(status)
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        // Stop the owned application first, then let vrmonitor close its runtime
        // normally. Force-killing vrserver on every successful session resembles
        // a crash to Steam. The job remains the bounded fallback on failure.
        unsafe {CloseHandle(self.application_job);}
        if let Some(application)=self.application.as_mut() {let _=application.wait();}
        shutdown_owned_steamvr(self.job);
        unsafe {CloseHandle(self.job);}
        let _=self.service.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{process::Stdio,time::{Duration,Instant}};
    fn idle() -> Command {
        let mut command=Command::new("cmd.exe");
        command.args(["/D","/C","ping -n 60 127.0.0.1 >NUL"]).stdout(Stdio::null()).stderr(Stdio::null());
        command
    }
    #[test]
    fn external_session_does_not_require_or_own_a_game() {
        let mut external=Session::start(&mut idle()).unwrap();
        let mut connection=Session::start(&mut idle()).unwrap();
        assert!(connection.poll_session(true).unwrap().is_none());
        drop(connection);
        external.ensure_runtime_running().unwrap();
    }
    #[test]
    fn drop_terminates_owned_runtime_and_application() {
        let mut session=Session::start(&mut idle()).unwrap();
        session.launch(&mut idle()).unwrap();
        assert!(session.poll().unwrap().is_none());
        let service= session.service.as_raw_handle();
        // Duplicate a handle so liveness can be checked after Session drops.
        use windows_sys::Win32::System::Threading::{GetCurrentProcess,WaitForSingleObject};
        use windows_sys::Win32::Foundation::{DuplicateHandle,DUPLICATE_SAME_ACCESS};
        let mut duplicate=std::ptr::null_mut();
        assert_ne!(unsafe {DuplicateHandle(GetCurrentProcess(),service,GetCurrentProcess(),&mut duplicate,0,0,DUPLICATE_SAME_ACCESS)},0);
        let started=Instant::now(); drop(session);
        assert!(started.elapsed()<Duration::from_secs(5));
        assert_eq!(unsafe {WaitForSingleObject(duplicate,1000)},0);
        unsafe {CloseHandle(duplicate);}
    }
    #[test]
    fn launcher_exit_does_not_end_its_owned_game() {
        let mut session=Session::start(&mut idle()).unwrap();
        let mut launcher=Command::new("powershell.exe");
        launcher.args(["-NoProfile","-Command","Start-Process ping.exe -ArgumentList @('-n','60','127.0.0.1') -NoNewWindow; exit 0"])
            .stdout(Stdio::null()).stderr(Stdio::null());
        session.launch(&mut launcher).unwrap();
        let deadline=Instant::now()+Duration::from_secs(5);
        while session.application.as_mut().unwrap().try_wait().unwrap().is_none() {
            assert!(Instant::now()<deadline,"launcher did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(session.poll().unwrap().is_none(),"the launcher's child must keep the session alive");
        drop(session);
    }
    #[test]
    fn runtime_helpers_do_not_keep_finished_application_alive() {
        let mut session=Session::start(&mut idle()).unwrap();
        let mut application=Command::new("cmd.exe");
        application.args(["/D","/C","exit 0"]);
        session.launch(&mut application).unwrap();
        let deadline=Instant::now()+Duration::from_secs(5);
        loop {
            if let Some(status)=session.poll().unwrap() {assert!(status.success());break;}
            assert!(Instant::now()<deadline,"runtime's ping child kept finished application alive");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(session.service.try_wait().unwrap().is_none());
    }
}
