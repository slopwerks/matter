//! Search query implementation.

use super::*;

pub(super) fn message_search_terms(query: &str) -> Vec<String> {
    query
        .to_lowercase()
        .split(|character: char| !character.is_alphanumeric())
        .filter(|term| !term.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

pub(super) fn escape_tantivy_phrase(term: &str) -> String {
    let mut escaped = String::with_capacity(term.len());
    for character in term.chars() {
        if matches!(character, '\\' | '"') {
            escaped.push('\\');
        }
        escaped.push(character);
    }
    escaped
}

pub(super) fn message_search_ngrams(term: &str) -> Vec<String> {
    let characters = term.chars().collect::<Vec<_>>();
    let gram_size = characters.len().min(3);
    if gram_size == 0 {
        return Vec::new();
    }
    characters
        .windows(gram_size)
        .map(|gram| gram.iter().collect())
        .collect()
}

/// Search the custom 1-3 character n-gram field with exact terms. Longer
/// inputs become overlapping trigrams joined with AND; the decoded event body
/// is still checked afterwards to reject reordered-gram false positives.
pub(super) fn message_search_index_query(terms: &[String]) -> String {
    terms
        .iter()
        .flat_map(|term| message_search_ngrams(term))
        .map(|gram| format!("body_ngram:\"{}\"", escape_tantivy_phrase(&gram)))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>()
        .join(" AND ")
}

pub(super) fn message_matches_search_terms(body: &str, terms: &[String]) -> bool {
    let normalized = body.to_lowercase();
    terms.iter().all(|term| normalized.contains(term))
}

pub(super) async fn begin_message_search(client: &Client, room_id: Option<&str>) -> (String, u64) {
    let user_id = client
        .user_id()
        .map(ToString::to_string)
        .unwrap_or_default();
    let key = format!("{user_id}\n{}", room_id.unwrap_or("*"));
    let generation = {
        let mut generations = SEARCH_QUERY_GENERATIONS.lock().await;
        let generation = generations.entry(key.clone()).or_default();
        *generation = generation.saturating_add(1);
        *generation
    };
    (key, generation)
}

pub(super) async fn message_search_is_current(key: &str, generation: u64) -> bool {
    SEARCH_QUERY_GENERATIONS.lock().await.get(key).copied() == Some(generation)
}

pub(super) fn message_search_cancelled() -> String {
    api_err(
        "search_cancelled",
        "Message search was cancelled.".to_string(),
    )
}

pub(super) fn ordered_event_cache_chunk_ids(
    metadata: Vec<ChunkMetadata>,
) -> Result<Vec<ChunkIdentifier>, String> {
    if metadata.is_empty() {
        return Ok(Vec::new());
    }
    let mut chunks = metadata
        .into_iter()
        .map(|chunk| (chunk.identifier, chunk))
        .collect::<HashMap<_, _>>();
    let first = chunks
        .values()
        .find(|chunk| chunk.previous.is_none())
        .map(|chunk| chunk.identifier)
        .ok_or_else(|| {
            api_err(
                "search",
                "Cached message chunks have no beginning".to_string(),
            )
        })?;
    let mut ordered = Vec::with_capacity(chunks.len());
    let mut current = Some(first);
    while let Some(identifier) = current {
        let chunk = chunks.remove(&identifier).ok_or_else(|| {
            api_err(
                "search",
                "Cached message chunks contain a cycle or broken link".to_string(),
            )
        })?;
        ordered.push(identifier);
        current = chunk.next;
    }
    if !chunks.is_empty() {
        return Err(api_err(
            "search",
            "Cached message chunks are disconnected".to_string(),
        ));
    }
    Ok(ordered)
}
