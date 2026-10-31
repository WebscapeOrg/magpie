#[cfg(all(test, feature = "agent", unix, not(target_os = "ios")))]
mod c023_hostile {
    use super::*;
    use crate::mail::tests::{account_fixture,fixture_tree,isolated};
    const ACCOUNT:&str="curated@example.test";
    fn fixture()->crate::mail::tests::AccountFixture { account_fixture(json!({"version":1,"activeId":ACCOUNT,"accounts":[{"email":ACCOUNT}]})) }
    #[test]
    fn readiness_refuses_malformed_records_and_claims_them_for_repair() {
        let base=json!({"version":2,"state":"ready","text":"Receipt — Invoice paid","expiresAt":0});
        assert!(overview_current(&base,1000));
        for (field,value) in [
            ("version",json!(1)),("version",json!("2")),("state",json!("running")),
            ("text",json!(" \t")),("text",json!("x".repeat(141))), ("text",json!("safe\nunsafe")),
            ("text",json!("safe\u{0085}unsafe")),("text",json!("<tag>")),("text",json!(null)),
            ("expiresAt",json!(-1)),("expiresAt",json!(1000)),("expiresAt",json!(1000.5)),("expiresAt",json!("2000")),("expiresAt",json!(null))
        ] {
            let mut row=base.clone();row[field]=value;
            assert!(!overview_current(&row,1000),"admitted {row}");
            if row["state"]!="running" {
                let mut saved=json!({"m":row});
                assert_eq!(claim_overviews(&mut saved,&["m".into()],false,1000).unwrap(),vec!["m"],"unrepairable {saved}");
            }
        }
    }
    #[tokio::test]
    async fn malformed_preferences_never_panic_or_rewrite_persisted_bytes() {
        if isolated(){return;}
        let _f=fixture(); let inbox=Inbox::default();
        for bad in [json!([]),json!("bad"),json!(23),json!({"paused":"yes"})] {
            let key=store::key(&["preferences",ACCOUNT]);store::write(&key,&bad).unwrap();
            let result=inbox.call("inbox.preferences",&json!({"accountId":ACCOUNT,"paused":true}),Arc::new(crate::providers::gmail::Session::default()),Arc::new(crate::local_mail::LocalMail::default())).await;
            assert!(result.is_err(),"accepted malformed storage {bad}");
            assert_eq!(store::read(&key).unwrap().unwrap(),bad,"must not rewrite malformed persisted state");
        }
    }
    #[tokio::test]
    async fn foreign_account_preferences_and_overviews_have_no_durable_effects() {
        if isolated(){return;}
        let f=fixture();let inbox=Inbox::default();let gmail=Arc::new(crate::providers::gmail::Session::default());let mail=Arc::new(crate::local_mail::LocalMail::default());
        let before=fixture_tree(&f.root);
        for method in ["inbox.preferences","inbox.overviews"] {
            let p=if method=="inbox.preferences" {json!({"accountId":"foreign@example.test","paused":true})} else {json!({"accountId":"foreign@example.test","ids":["m"]})};
            assert_eq!(inbox.call(method,&p,gmail.clone(),mail.clone()).await,Err("mail_account_unknown"));
        }
        assert_eq!(fixture_tree(&f.root),before);
    }
    #[tokio::test]
    async fn pause_prevents_hidden_mail_work_before_any_local_or_provider_read() {
        if isolated(){return;}
        let f=fixture();store::write(&store::key(&["preferences",ACCOUNT]),&json!({"paused":true,"allowRemoteImages":false})).unwrap();
        let before=fixture_tree(&f.root);let inbox=Inbox::default();
        inbox.prepare(ACCOUNT,Arc::new(crate::providers::gmail::Session::default()),Arc::new(crate::local_mail::LocalMail::default())).await.unwrap();
        assert_eq!(fixture_tree(&f.root),before);
    }
    #[test]
    fn account_incarnation_blocks_remove_and_readd_even_with_identical_content() {
        if isolated(){return;}
        let f=fixture();
        let token=crate::account::with_incarnation(None,Ok).unwrap();
        let directory=crate::platform::private_fs::directories(&f.config,&["omamail"],false).unwrap().unwrap();
        let bytes=std::fs::read(f.config.join("omamail/accounts.json")).unwrap();
        crate::platform::private_fs::atomic_replace(&directory,"accounts.json",&bytes).unwrap();
        let before=fixture_tree(&f.root);let mut reached=false;
        assert_eq!(crate::account::with_incarnation(Some(&token),|_|{reached=true;Ok(())}),Err("overview_account_changed"));
        assert!(!reached,"old completion reached cache-writing callback");
        assert_eq!(fixture_tree(&f.root),before);
    }
    #[test]
    fn active_inbox_results_survive_cache_pruning() {
        let mut saved=json!({});let mut protect=std::collections::HashSet::new();
        for n in 0..6000 {let id=format!("m{n}");protect.insert(id.clone());saved[&id]=json!({"updated":n,"version":2,"state":"ready","text":"Prepared mail","expiresAt":0});}
        finish_overviews_protected(&mut saved,&["new".into()],&Ok(json!([{"id":"new","text":"New prepared mail","timeSensitive":false}])),&protect).unwrap();
        for id in protect {assert!(overview_current(&saved[&id],now()),"active inbox entry {id} was evicted");}
    }
}


#[cfg(all(test, feature="agent", unix, not(target_os="ios")))]
mod c023_preference_hostile {
 use super::*;
 const ACCOUNT:&str="curated@example.test";
 #[tokio::test]
 async fn preference_mutation_refuses_registry_lock_contention_without_writing() {
  if crate::mail::tests::isolated(){return;}
  let f=crate::mail::tests::account_fixture(json!({"version":1,"activeId":ACCOUNT,"accounts":[{"email":ACCOUNT}]}));
  let directory=crate::platform::private_fs::directories(&f.config,&["omamail"],false).unwrap().unwrap();
  let _guard=crate::platform::private_fs::lock_exclusive(&directory,".accounts.lock").unwrap();
  let before=crate::mail::tests::fixture_tree(&f.root);
  let result=Inbox::default().call("inbox.preferences",&json!({"accountId":ACCOUNT,"allowRemoteImages":true}),Arc::new(crate::providers::gmail::Session::default()),Arc::new(crate::local_mail::LocalMail::default())).await;
  assert!(result.is_err(),"preference mutation ignored registry lock: {result:?}");
  assert_eq!(crate::mail::tests::fixture_tree(&f.root),before,"locked mutation changed persistent state");
 }
 #[test]
 fn readiness_rejects_every_explicit_format_control() {
  for c in [0x200b,0x200f,0x202a,0x202e,0x2060,0x206f,0xfeff] {
   let text=format!("safe{}unsafe",char::from_u32(c).unwrap());
   assert!(!overview_current(&json!({"version":2,"state":"ready","text":text,"expiresAt":0}),1000));
  }
 }
}
