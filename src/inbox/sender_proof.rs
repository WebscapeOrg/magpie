//! Who a mail really came from, as far as Gmail can say. The From, display name and Reply-To are
//! the sender's own words; only the result Gmail itself recorded in Authentication-Results says the
//! domain signed for that address.
//! Invariant: only a domain-aligned pass recorded by Gmail counts: DMARC with `header.from` equal
//! to the From domain, or DKIM aligned with it. A missing, duplicated or ambiguous result, or one
//! added by any other server, is no proof. SPF alone never is.
use crate::message::content::addresses;
use serde_json::Value;

const GMAIL: &str = "mx.google.com";

/// The sender of one mail: the address (lower-cased), display name and Reply-To addresses, and
/// whether Gmail proved the domain behind the address.
#[derive(Clone, Debug, PartialEq)]
pub(super) struct Sender {
    pub email: String,
    pub name: String,
    pub reply_to: Vec<String>,
    pub proven: bool,
}

impl Sender {
    /// Whether two mails name exactly one sender: the same address, display name and Reply-To.
    pub(super) fn same_as(&self, other: &Sender) -> bool {
        self.email == other.email && self.name == other.name && self.reply_to == other.reply_to
    }
}

/// The values of one header among the top-level headers of a Gmail message, in order.
/// `header()` returns only the first, and a sender can add headers of their own.
fn header_values<'a>(raw: &'a Value, name: &str) -> Vec<&'a str> {
    raw["payload"]["headers"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .filter(|header| header["name"].as_str().is_some_and(|found| found.eq_ignore_ascii_case(name)))
        .filter_map(|header| header["value"].as_str())
        .collect()
}

/// The mail's sender, or None when its From is not exactly one address.
pub(super) fn sender(raw: &Value) -> Option<Sender> {
    let from = single(header_values(raw, "From"))?;
    let [address] = addresses(from).try_into().ok()?;
    let email = address["email"].as_str()?.to_lowercase();
    // Invariant: an offer shows Dave the address to trust, so it must read as it really is.
    if email.chars().any(invisible_or_reordering) {
        return None;
    }
    let domain = email.rsplit_once('@').map(|(_, domain)| domain.to_owned()).filter(|domain| !domain.is_empty())?;
    let replies = header_values(raw, "Reply-To");
    if replies.len() > 1 {
        return None;
    }
    let mut reply_to: Vec<String> = replies.first().map(|value| addresses(value)).unwrap_or_default().iter().filter_map(|reply| reply["email"].as_str().map(str::to_lowercase)).collect();
    reply_to.sort();
    let proven = single_gmail_result(raw).is_some_and(|result| aligned(&result, &domain));
    Some(Sender { email, name: address["name"].as_str().unwrap_or("").trim().to_owned(), reply_to, proven })
}

fn invisible_or_reordering(character: char) -> bool {
    matches!(character, '\u{ad}' | '\u{34f}' | '\u{61c}' | '\u{115f}'..='\u{1160}' | '\u{17b4}'..='\u{17b5}' | '\u{180b}'..='\u{180f}' | '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{3164}' | '\u{fe00}'..='\u{fe0f}' | '\u{feff}' | '\u{ffa0}' | '\u{fff9}'..='\u{fffb}' | '\u{1d173}'..='\u{1d17a}' | '\u{e0000}'..='\u{e0fff}')
}

fn single(values: Vec<&str>) -> Option<&str> {
    let [value] = values.as_slice() else { return None };
    Some(*value)
}

/// Gmail's own result: the first Authentication-Results header, which Gmail prepends, and only when
/// it is the only one naming Gmail as its author, since a sender can add a forged one below it.
fn single_gmail_result(raw: &Value) -> Option<String> {
    let results = header_values(raw, "Authentication-Results");
    let gmail: Vec<&&str> = results.iter().filter(|value| authored_by_gmail(value)).collect();
    match (results.first(), gmail.as_slice()) {
        (Some(first), [only]) if first == *only => Some((**only).to_owned()),
        _ => None,
    }
}

fn authored_by_gmail(value: &str) -> bool {
    clauses(value).first().is_some_and(|authserv| authserv.eq_ignore_ascii_case(GMAIL))
}

/// A space inside quotes, written so that `pairs` cannot read what follows it as a field of its own.
fn unsplit(character: char, quoted: bool) -> char {
    if quoted && character.is_whitespace() { '\u{1}' } else { character }
}

/// The header's `;`-separated clauses with comments removed, each trimmed. Comments may hold `;`
/// and any text a sender chose, so they are taken out before the header is split.
fn clauses(value: &str) -> Vec<String> {
    let mut parts = vec![String::new()];
    let (mut comment, mut quoted, mut escaped) = (0usize, false, false);
    for character in value.chars() {
        if escaped {
            escaped = false;
            if comment == 0 {
                parts.last_mut().expect("parts is never empty").push(unsplit(character, quoted));
            }
            continue;
        }
        match character {
            '\\' if quoted || comment > 0 => escaped = true,
            // Invariant: a sender's quoted address can sit inside Gmail's comment, so quotes count there too
            // and a bracket or `;` inside them cannot end the comment.
            '"' => {
                quoted = !quoted;
                if comment == 0 {
                    parts.last_mut().expect("parts is never empty").push(character);
                }
            }
            '(' if !quoted => comment += 1,
            ')' if !quoted && comment > 0 => comment -= 1,
            ';' if !quoted && comment == 0 => parts.push(String::new()),
            _ if comment == 0 => parts.last_mut().expect("parts is never empty").push(unsplit(character, quoted)),
            _ => {}
        }
    }
    // Invariant: a header whose comments or quotes do not close cannot be read, so it proves nothing.
    if comment != 0 || quoted {
        return Vec::new();
    }
    parts.iter().map(|part| part.trim().to_owned()).collect()
}

/// The `name=value` pairs of one clause, the first being `method=result`.
fn pairs(clause: &str) -> Vec<(String, String)> {
    clause
        .split_whitespace()
        .filter_map(|token| token.split_once('='))
        .map(|(name, value)| (name.to_ascii_lowercase(), value.trim_matches('"').to_ascii_lowercase()))
        .collect()
}

/// Whether the result holds a domain-aligned pass for `domain`.
fn aligned(result: &str, domain: &str) -> bool {
    let parsed: Vec<Vec<(String, String)>> = clauses(result).iter().skip(1).map(|clause| pairs(clause)).filter(|pairs| !pairs.is_empty()).collect();
    let method = |clause: &[(String, String)], name: &str| clause.first().is_some_and(|(found, _)| found.split('/').next() == Some(name));
    let result_of = |clause: &[(String, String)]| clause.first().map(|(_, value)| value.clone()).unwrap_or_default();
    let value = |clause: &[(String, String)], name: &str| clause.iter().find(|(found, _)| found == name).map(|(_, value)| value.clone());
    let dmarc: Vec<&Vec<(String, String)>> = parsed.iter().filter(|clause| method(clause, "dmarc")).collect();
    if dmarc.len() > 1 {
        return false;
    }
    if let Some(clause) = dmarc.first() {
        match result_of(clause).as_str() {
            "pass" => return value(clause, "header.from").as_deref() == Some(domain),
            // No policy to check against; a signature aligned with the domain can still prove it.
            "none" | "bestguesspass" => {}
            _ => return false,
        }
    }
    // Invariant: a DKIM result counts only before SPF, the first place text a sender chose appears.
    // Gmail writes DKIM first; a mail with it later can still be proven by DMARC above.
    parsed.iter().take_while(|clause| !method(clause, "spf")).filter(|clause| method(clause, "dkim") && result_of(clause) == "pass").any(|clause| {
        let signer = value(clause, "header.d").or_else(|| value(clause, "header.i").map(|identity| identity.rsplit('@').next().unwrap_or("").to_owned()));
        signer.is_some_and(|signer| !signer.is_empty() && registrable_aligned(&signer, domain))
    })
}

/// DMARC's relaxed alignment: the same registrable domain. Private suffixes such as `uk.com` or
/// `github.io` count, because strangers register beside each other under them.
fn registrable_aligned(signer: &str, domain: &str) -> bool {
    psl::domain_str(signer).is_some_and(|registrable| psl::domain_str(domain) == Some(registrable))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn mail(headers: Value) -> Value {
        json!({"id":"m1","payload":{"mimeType":"text/plain","headers":headers,"body":{"data":"eA"}}})
    }
    const REAL: &str = "mx.google.com;\r\n       dkim=pass header.i=@uptimerobot.example header.s=google header.b=abc123;\r\n       spf=pass (google.com: domain of alert@uptimerobot.example designates 192.0.2.1 as permitted sender; really) smtp.mailfrom=alert@uptimerobot.example;\r\n       dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=uptimerobot.example";
    fn headers(extra: &[(&str, &str)]) -> Value {
        let mut list: Vec<Value> = vec![json!({"name":"Delivered-To","value":"me@example.test"})];
        list.extend(extra.iter().map(|(name, value)| json!({"name":name,"value":value})));
        list.push(json!({"name":"From","value":"UptimeRobot <alert@uptimerobot.example>"}));
        list.push(json!({"name":"Subject","value":"Monitor is UP"}));
        json!(list)
    }
    fn proven(extra: &[(&str, &str)]) -> bool {
        sender(&mail(headers(extra))).is_some_and(|sender| sender.proven)
    }

    #[test]
    fn a_dmarc_pass_recorded_by_gmail_for_the_from_domain_proves_the_sender() {
        assert!(proven(&[("Authentication-Results", REAL)]));
        let found = sender(&mail(headers(&[("Authentication-Results", REAL)]))).unwrap();
        assert_eq!((found.email.as_str(), found.name.as_str()), ("alert@uptimerobot.example", "UptimeRobot"));
    }

    fn proven_from(from: &str, result: &str) -> bool {
        let list = json!([{"name":"Authentication-Results","value":result},{"name":"From","value":from},{"name":"Subject","value":"x"}]);
        sender(&mail(list)).is_some_and(|sender| sender.proven)
    }

    #[test]
    fn a_stranger_under_a_shared_suffix_proves_nothing_but_the_same_organisation_does() {
        let signed_by = |domain: &str| format!("mx.google.com; dkim=pass header.i=@{domain} header.s=a header.b=b; dmarc=none header.from=victim.uk.com");
        assert!(!proven_from("Victim <billing@victim.uk.com>", &signed_by("evil.uk.com")));
        assert!(proven_from("Victim <billing@victim.uk.com>", &signed_by("mail.victim.uk.com")));
        assert!(!proven_from("Page <me@alice.github.io>", "mx.google.com; dkim=pass header.i=@mallory.github.io; dmarc=none header.from=alice.github.io"));
        assert!(proven_from("Shop <news@mail.shop.co.uk>", "mx.google.com; dkim=pass header.i=@shop.co.uk; dmarc=none header.from=mail.shop.co.uk"));
    }

    #[test]
    fn a_header_whose_comments_or_quotes_do_not_close_proves_nothing() {
        for broken in [
            "mx.google.com; dkim=pass header.i=@uptimerobot.example; spf=none (open comment",
            "mx.google.com; dkim=pass header.i=@uptimerobot.example; x=\"open quote",
            "mx.google.com; spf=pass (a) ; dkim=pass header.i=@uptimerobot.example ; ((( smtp.mailfrom=a; dmarc=fail",
        ] {
            assert!(!proven(&[("Authentication-Results", broken)]), "{broken}");
        }
        assert!(proven(&[("Authentication-Results", "mx.google.com; dkim=pass (2048-bit key; good) header.i=@uptimerobot.example")]));
    }

    #[test]
    fn an_aligned_dkim_pass_also_proves_it_but_spf_alone_does_not() {
        assert!(proven(&[("Authentication-Results", "mx.google.com; dkim=pass header.i=@uptimerobot.example; spf=none smtp.mailfrom=x")]));
        assert!(proven(&[("Authentication-Results", "mx.google.com; dkim=pass header.d=mail.uptimerobot.example header.s=a; dmarc=none header.from=uptimerobot.example")]), "relaxed alignment");
        assert!(!proven(&[("Authentication-Results", "mx.google.com; spf=pass smtp.mailfrom=alert@uptimerobot.example")]));
        assert!(!proven(&[("Authentication-Results", "mx.google.com; dkim=pass header.i=@evil.example; dmarc=none header.from=uptimerobot.example")]), "signed by a domain the From does not name");
        assert!(!proven(&[("Authentication-Results", "mx.google.com; dkim=fail header.i=@uptimerobot.example; dmarc=fail header.from=uptimerobot.example")]));
    }

    #[test]
    fn a_header_added_by_anyone_other_than_gmail_proves_nothing() {
        for (name, value) in [
            ("Authentication-Results", "relay.evil.example; dmarc=pass header.from=uptimerobot.example"),
            ("Authentication-Results", "mx.google.com.evil.example; dmarc=pass header.from=uptimerobot.example"),
            ("X-Authentication-Results", REAL),
            ("ARC-Authentication-Results", REAL),
        ] {
            assert!(!proven(&[(name, value)]), "accepted {value}");
        }
        assert!(sender(&mail(json!([{"name":"From","value":"UptimeRobot <alert@uptimerobot.example>"}]))).is_some_and(|sender| !sender.proven), "a missing header");
    }

    #[test]
    fn a_second_gmail_result_or_one_below_another_authors_result_is_ambiguous() {
        // A sender can add a header naming Gmail below the real one, so two are never trusted.
        assert!(!proven(&[("Authentication-Results", REAL), ("Authentication-Results", "mx.google.com; dmarc=pass header.from=uptimerobot.example")]));
        assert!(!proven(&[("Authentication-Results", "relay.evil.example; dmarc=fail header.from=x.example"), ("Authentication-Results", REAL)]), "Gmail's result is not the topmost");
        assert!(proven(&[("Authentication-Results", REAL), ("Authentication-Results", "relay.example; dmarc=pass header.from=x.example")]), "another server's result below Gmail's is ignored");
    }

    #[test]
    fn a_dkim_result_written_inside_the_senders_part_of_the_header_is_refused() {
        let inside = "mx.google.com; spf=pass (domain of \"x) ; dkim=pass header.i=@uptimerobot.example (y\"@evil.example) smtp.mailfrom=evil.example";
        assert!(!proven(&[("Authentication-Results", inside)]), "{inside}");
        assert!(proven(&[("Authentication-Results", "mx.google.com; dkim=pass header.i=@uptimerobot.example; spf=none smtp.mailfrom=a")]));
    }

    #[test]
    fn a_result_forged_inside_a_quoted_address_in_gmails_comment_is_refused() {
        let forged = "mx.google.com; spf=pass (google.com: domain of \"a)b;dmarc=pass header.from=bank.example;c(d\"@attacker.example designates 192.0.2.1 as permitted sender) smtp.mailfrom=\"a\"@attacker.example";
        assert!(!proven_from("Bank <news@bank.example>", forged));
    }

    #[test]
    fn a_field_written_inside_a_quoted_value_is_not_read() {
        let forged = "mx.google.com; dkim=pass header.i=\"x header.d=bank.example\" header.s=s1";
        assert!(!proven_from("Bank <news@bank.example>", forged));
    }

    #[test]
    fn an_address_that_hides_or_reorders_characters_is_not_a_sender() {
        for address in ["news\u{202e}elpmaxe.knab@bank.example", "news\u{200b}@bank.example", "news\u{2066}@bank.example", "news@ba\u{feff}nk.example", "news\u{34f}@bank.example", "news\u{2028}@bank.example", "news\u{3164}@bank.example", "news\u{fe0f}@bank.example", "news\u{fff9}@bank.example", "news\u{e0041}@bank.example"] {
            let from = format!("Bank <{address}>");
            assert!(sender(&mail(json!([{"name":"From","value":from}]))).is_none(), "{address:?}");
        }
        assert!(sender(&mail(json!([{"name":"From","value":"Bank <news@bank.example>"}]))).is_some());
    }

    #[test]
    fn a_pass_for_another_domain_or_a_comment_that_looks_like_a_result_is_refused() {
        assert!(!proven(&[("Authentication-Results", "mx.google.com; dmarc=pass header.from=evil.example")]));
        assert!(!proven(&[("Authentication-Results", "mx.google.com (dmarc=pass header.from=uptimerobot.example; dmarc=pass header.from=uptimerobot.example) ; spf=pass smtp.mailfrom=x")]));
        assert!(!proven(&[("Authentication-Results", "mx.google.com; dmarc=pass header.from=uptimerobot.example; dmarc=fail header.from=uptimerobot.example")]), "two DMARC results");
        assert!(!proven(&[("Authentication-Results", "mx.google.com; dmarc=temperror header.from=uptimerobot.example; dkim=pass header.i=@uptimerobot.example")]), "DMARC could not be judged");
    }

    #[test]
    fn two_from_headers_or_addresses_or_reply_tos_are_not_one_sender() {
        let two = json!([{"name":"From","value":"A <a@example.test>"},{"name":"From","value":"B <b@example.test>"},{"name":"Authentication-Results","value":REAL}]);
        assert!(sender(&mail(two)).is_none());
        assert!(sender(&mail(json!([{"name":"From","value":"A <a@example.test>, B <b@example.test>"}]))).is_none());
        assert!(sender(&mail(json!([{"name":"From","value":"A <a@example.test>"},{"name":"Reply-To","value":"x@example.test"},{"name":"Reply-To","value":"y@example.test"}]))).is_none());
    }

    #[test]
    fn the_same_sender_means_the_same_address_display_name_and_reply_to() {
        let one = |name: &str, reply: Option<&str>| {
            let mut list = vec![json!({"name":"From","value":format!("{name} <alert@UptimeRobot.example>")})];
            if let Some(reply) = reply { list.push(json!({"name":"Reply-To","value":reply})); }
            sender(&mail(json!(list))).unwrap()
        };
        assert!(one("UptimeRobot", None).same_as(&one("UptimeRobot", None)), "the address's case does not matter");
        assert!(!one("UptimeRobot", None).same_as(&one("UptimeRobot Support", None)), "a differing display name");
        assert!(!one("UptimeRobot", None).same_as(&one("UptimeRobot", Some("elsewhere@example.test"))), "a differing reply-to");
        assert!(one("UptimeRobot", Some("help@example.test")).same_as(&one("UptimeRobot", Some("help@example.test"))));
    }
}
