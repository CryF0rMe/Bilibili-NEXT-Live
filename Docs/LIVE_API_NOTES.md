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

The public search service intermittently returns HTTP 412. A separate
`live_user` search request and one exact Chinese-title request returned 412 during
verification, so the app uses the verified `live_room` search and reports HTTP
errors visibly. It does not ask for cookies, bypass service challenges, or replace
failed searches with fabricated results. Recommendations and categories remain
independent of search availability.

The existing H5 playback endpoint was also checked with a room obtained from
search: HTTP 200, `code: 0`, and two HTTPS stream URLs in `data.durl`.

## Regression checks and device validation

`Tests/Fixtures` contains reduced real captures with tracking/session fields
removed. They are test input only and are not part of the Xcode app target.
`Tests/LiveContractTests.swift` checks envelope errors, metadata, normalization,
cookie isolation, pagination, retries, and stale request results. The CI command
compiles the actual API and model source files before running these checks.

The player view is preserved byte-for-byte from the device-tested implementation
at `3e00aadff`. Discovery card navigation, actual image loading, search/category
responses from the user's network, and continued video/audio/fullscreen playback
should still be validated on a device with the new IPA.
