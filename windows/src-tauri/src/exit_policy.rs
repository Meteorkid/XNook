use std::sync::atomic::{AtomicU8, Ordering};

const IDLE: u8 = 0;
const SAVING: u8 = 1;
const CONFIRMING: u8 = 2;
const AUTHORIZED: u8 = 3;

#[derive(Debug, PartialEq, Eq)]
pub enum ExitRequest { SaveFirst, AskToForce, Ignore }

#[derive(Default)]
pub struct ExitPolicy { state: AtomicU8 }

impl ExitPolicy {
    pub fn request(&self) -> ExitRequest {
        loop {
            let state = self.state.load(Ordering::SeqCst);
            let (next, action) = match state {
                IDLE => (SAVING, ExitRequest::SaveFirst),
                SAVING => (CONFIRMING, ExitRequest::AskToForce),
                _ => return ExitRequest::Ignore,
            };
            if self.state.compare_exchange(state, next, Ordering::SeqCst, Ordering::SeqCst).is_ok() { return action; }
        }
    }

    pub fn confirm_saved(&self) -> Result<(), String> {
        // 原生确认框打开后，前端的迟到回调不能越过用户正在做的决定。
        self.state.compare_exchange(SAVING, AUTHORIZED, Ordering::SeqCst, Ordering::SeqCst)
            .map(|_| ()).map_err(|_| "没有待确认的退出请求，或原生退出确认尚未结束".into())
    }

    pub fn cancel_save(&self) -> Result<(), String> {
        match self.state.compare_exchange(SAVING, IDLE, Ordering::SeqCst, Ordering::SeqCst) {
            Ok(_) | Err(IDLE) => Ok(()),
            Err(_) => Err("原生退出确认尚未结束，无法取消保存请求".into()),
        }
    }

    pub fn resolve_force(&self, confirmed: bool) -> bool {
        self.state.compare_exchange(CONFIRMING, if confirmed { AUTHORIZED } else { IDLE }, Ordering::SeqCst, Ordering::SeqCst).is_ok() && confirmed
    }

    pub fn authorized(&self) -> bool { self.state.load(Ordering::SeqCst) == AUTHORIZED }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_request_requires_saved_confirmation() {
        let policy = ExitPolicy::default();
        assert!(policy.confirm_saved().is_err()); assert!(!policy.authorized());
        assert_eq!(policy.request(), ExitRequest::SaveFirst); assert!(!policy.authorized());
        policy.confirm_saved().unwrap(); assert!(policy.authorized()); assert_eq!(policy.request(), ExitRequest::Ignore);
    }

    #[test]
    fn frontend_cancel_allows_fresh_request_but_cannot_bypass_native_confirmation() {
        let policy = ExitPolicy::default();
        assert!(policy.cancel_save().is_ok());
        assert_eq!(policy.request(), ExitRequest::SaveFirst);
        policy.cancel_save().unwrap();
        assert!(policy.confirm_saved().is_err());
        assert_eq!(policy.request(), ExitRequest::SaveFirst);
        assert_eq!(policy.request(), ExitRequest::AskToForce);
        assert!(policy.cancel_save().is_err());
        assert!(policy.confirm_saved().is_err());
        assert!(!policy.authorized());
    }

    #[test]
    fn repeated_requests_open_exactly_one_native_confirmation() {
        let policy = ExitPolicy::default();
        assert_eq!(policy.request(), ExitRequest::SaveFirst);
        assert_eq!(policy.request(), ExitRequest::AskToForce);
        assert_eq!(policy.request(), ExitRequest::Ignore);
        assert!(policy.confirm_saved().is_err()); assert!(!policy.authorized());
    }

    #[test]
    fn cancelled_native_confirmation_keeps_running_and_allows_fresh_save() {
        let policy = ExitPolicy::default(); policy.request(); policy.request();
        assert!(!policy.resolve_force(false)); assert!(!policy.authorized());
        assert!(policy.confirm_saved().is_err());
        assert_eq!(policy.request(), ExitRequest::SaveFirst);
    }

    #[test]
    fn force_exit_requires_an_open_dialog_and_positive_user_choice() {
        let policy = ExitPolicy::default();
        assert!(!policy.resolve_force(true)); assert!(!policy.authorized());
        policy.request(); policy.request();
        assert!(policy.resolve_force(true)); assert!(policy.authorized());
        assert_eq!(policy.request(), ExitRequest::Ignore);
    }
}
