//! Reuse the search order, but verify the small page before returning its IDs.
//! Expunged candidates do not become ghost rows, and UIDVALIDITY is checked
//! even on a cache hit. Four folders per call keeps page assembly resumable.
use super::*;

impl Snapshot {
    pub(super) async fn verify_page(
        &mut self,
        params: &Value,
        cursor: Option<&Cursor>,
        limit: usize,
    ) -> Result<bool> {
        let offset = self.offset(cursor);
        let ordered = self.ordered.as_ref().ok_or("imap_invalid_response")?;
        let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for &(folder_index, message_index) in ordered.iter().skip(offset).take(limit) {
            if !self.verified.contains(&(folder_index, message_index)) {
                groups.entry(folder_index).or_default().push(message_index);
            }
        }
        let gate = gate(self.owner).await;
        let mut work = FuturesUnordered::new();
        for (folder_index, indices) in groups.into_iter().take(WORKERS) {
            let folder = &self.folders[folder_index];
            let gate = gate.clone();
            work.push(worker(gate, async move {
                let uids = indices
                    .iter()
                    .map(|message_index| folder.messages[*message_index].uid.to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                let (mut wire, key) = acquire(params).await?;
                let selected =
                    command(&mut wire, &format!("SELECT {}", quote(&folder.name)?)).await?;
                if Some(validity(&selected)?) != folder.validity {
                    return Err("imap_search_expired");
                }
                let data = command(&mut wire, &format!("UID FETCH {uids} (UID)")).await?;
                let present = fetched_dates(&data)?;
                release(wire, key).await;
                Ok((
                    folder_index,
                    indices
                        .into_iter()
                        .map(|message_index| {
                            (
                                message_index,
                                present.contains_key(&folder.messages[message_index].uid),
                            )
                        })
                        .collect::<Vec<_>>(),
                ))
            }));
        }
        let mut missing = BTreeSet::new();
        while let Some(result) = work.next().await {
            let (folder_index, results) = result?;
            for (message_index, present) in results {
                if present {
                    self.verified.insert((folder_index, message_index));
                } else {
                    missing.insert((folder_index, message_index));
                }
            }
        }
        drop(work);
        self.ordered
            .as_mut()
            .unwrap()
            .retain(|location| !missing.contains(location));
        // Invariant: Deletion may bring more candidates into the page. Verify those on
        // the next continuation rather than returning a short or stale page.
        Ok(self
            .ordered
            .as_ref()
            .unwrap()
            .iter()
            .skip(self.offset(cursor))
            .take(limit)
            .all(|location| self.verified.contains(location)))
    }
}
