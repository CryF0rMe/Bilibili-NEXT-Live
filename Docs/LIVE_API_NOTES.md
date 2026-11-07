# Public live discovery API verification

Verified on 2026-11-07 with unauthenticated HTTPS GET requests, `User-Agent:
Mozilla/5.0` and `Referer: https://live.bilibili.com/`. No Cookie header was sent.

| Purpose | Endpoint and tested parameters | Observed response |
| --- | --- | --- |
| Original list | `api.live.bilibili.com/xlive/web-interface/v1/second/getList?platform=web&parent_area_id=0&area_id=0&page=1` | HTTP 200, service `code: -352`, no data. Specifying a real area on this same endpoint also returned `-352`. |
| Recommendations | `api.live.bilibili.com/xlive/web-interface/v1/webMain/getMoreRecList?platform=web&page=1` | HTTP 200, `code: 0`, `data.recommend_room_list` with 12 real rooms. Page 2 also returned 12 rooms, with one overlapping room in the captures. |
| First-page fallback | `api.live.bilibili.com/xlive/web-interface/v1/webMain/getList?platform=web` | HTTP 200, `code: 0`, `data.recommend_room_list` with 12 rooms. Used only as a first-page fallback; no invented pagination. |
| Category index | `api.live.bilibili.com/room/v1/Area/getList` | HTTP 200, `code: 0`, `data` array with 12 parent categories. Child area IDs are strings. |
| Category rooms | `api.live.bilibili.com/room/v3/area/getRoomList?platform=web&parent_area_id=2&area_id=0&sort_type=online&page=1&page_size=30` | HTTP 200, `code: 0`, 30 rooms in `data.list` and a total in `data.count`. Page 2 and the CS2 child area (`area_id=89`) also succeeded. |
| Search | `api.bilibili.com/x/web-interface/search/type?search_type=live_room&keyword=CS2&page=1` | HTTP 200, `code: 0`, 40 rooms in `data.result`, with `numPages`. Searching a returned streamer's nickname also returned that live room. A title-keyword search for `3X3` returned 40 rooms with 38 title hits. |

## Parsing and failure handling

Room IDs may appear as `roomid`, `room_id`, or `id`. Covers have several field
names, and search covers can begin with `//`. Category names differ between the
recommendation, area, and search payloads. Search text can include `<em>` highlight
markup. The shared decoder normalizes these fields, rejects invalid IDs, and
filters entries explicitly marked offline. Popularity is labeled as popularity,
not a precise concurrent viewer count.

HTTP 200 does not imply a successful service response. The former implementation
ignored `code: -352` and treated the missing data as an empty array. Missing or
malformed success payloads now produce an error, while an actual empty result is
handled as empty. Overlapping pages are deduplicated by room ID. A wholly repeated
page ends pagination; a failed page can be retried without discarding loaded rooms.
Generation guards prevent old search/category/page requests from overwriting a
new selection or refresh.

The initial unsigned search endpoint returned HTTP 412 on the user's device.
Follow-up verification compared both requests for `advent`: the unsigned endpoint
returned HTTP 412, while `/x/web-interface/wbi/search/type` with normal WBI signing
returned HTTP 200, `code: 0`, and `CS-advent` (room 1883358196). Public signing image
keys were obtained from anonymous `/x/web-interface/nav`, whose `code: -101` still
included `data.wbi_img`. The client now uses this signed endpoint, the upstream's
signing algorithm, canonical RFC-3986 query encoding, and a short in-memory key
cache. It continues to send no account cookies or login credentials. Service
challenges are reported instead of automatically circumvented.

The existing H5 playback endpoint was also checked with a room obtained from
search: HTTP 200, `code: 0`, and two HTTPS stream URLs in `data.durl`.

However, checking the actual playlists for three subsequently recommended rooms
showed that their legacy/TS URLs timed out. The modern
`/xlive/web-room/v2/index/getRoomPlayInfo` endpoint, requested with `protocol=1`,
`format=1,2`, `codec=0`, and `qn=400`, returned AVC/HLS sources. For all three rooms,
the fMP4 playlist returned HTTP 200 with `#EXTM3U` while the sampled TS playlist
timed out. Playback therefore prefers HLS/fMP4, keeps all compatible CDNs, and
retains HLS/TS and the old H5 API as fallbacks where applicable. It never passes
FLV or an unsupported codec to AVPlayer merely because the metadata API succeeded.

The reproducible `live-diagnostics.yml` workflow logs service results, format and
codec names, and playlist reachability. It does not log account cookies, signing
keys, signatures, or full temporary stream URLs.

## Regression checks and device validation

`Tests/Fixtures` contains reduced real captures with tracking/session fields
removed. They are test input only and are not part of the Xcode app target.
`Tests/LiveContractTests.swift` checks envelope errors, metadata, normalization,
cookie isolation, signing, source selection, pagination, retries, and stale
request results. It also exercises AVPlayer's actual failed-item-to-H.264-source
transition and verifies that stop releases playback and ignores old callbacks.
The CI command compiles the actual API, browse model and playback state sources.

Audio activation, inline/fullscreen ownership and window-aware orientation
restoration are retained. The playback state now watches AVPlayerItem failure and
buffering, attempts another supplied CDN after a failure or 12-second connection
timeout, and shows an actionable error after exhausting sources. Device testing
should cover the reported search term, several recommendation cards, source
loading feedback, audio, fullscreen, and leaving the room.
