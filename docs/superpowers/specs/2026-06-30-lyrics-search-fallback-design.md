# Lyrics Search Fallback Design

## Problem

LRCLIB's exact `/api/get` endpoint returns 404 when the player artist name is a shortened alias. For example, `唯一` by `邓紫棋` is stored by LRCLIB as `G.E.M. 邓紫棋`, so synchronized lyrics exist but X Nook never receives them.

## Design

Keep the exact lookup as the first request. If it returns 404, call `/api/search` with the same title and artist. Rank search results using:

1. Exact normalized track title.
2. Artist containment after removing punctuation and whitespace.
3. Smallest duration difference when the player duration is available.
4. Presence of synchronized lyrics.

Use the highest-ranked result that contains synchronized or plain lyrics. Other HTTP failures remain failures and do not trigger a second request.

`MediaManager` passes the current track duration to `LyricsManager` so similarly named versions can be distinguished.

## Verification

Add a regression test proving that `唯一` by `邓紫棋` selects the `G.E.M. 邓紫棋` search result. Then run all tests, rebuild and restart X Nook, and observe the ticker across multiple lyric timestamps.
