# Bilibili NEXT Live

Community development fork intended to add live-stream browsing and playback to the iOS client.

Upstream: https://github.com/wzk112/Bilibili-NEXT

This repository is not affiliated with Bilibili. Original project license and attribution should be retained when importing the source.

## Build status

The unsigned iOS app builds with Xcode 26 / Swift 6.2. The build at `3e00aadff`
was tested in LiveContainer: live video, sound, entering/exiting landscape
fullscreen, and direct room-number entry all worked on a device.

## Live discovery

The Live tab includes public recommendations, thumbnail cards, streamer names,
titles, categories and popularity, plus pull-to-refresh and paginated loading.
Search accepts a streamer name or title keyword; a numeric search opens the room
directly. The category picker supports parent categories and searchable subareas.
Direct room-number entry remains available in the toolbar.

Public discovery uses a separate cookie-free session and checks both HTTP status
and the Bilibili service code. Errors remain visible instead of appearing as an
empty list. See [verified API notes](Docs/LIVE_API_NOTES.md) for endpoint details
and temporary service restrictions.

## CI

The workflow imports pinned upstream revision
`67bcc018d408e91b8427f2a7e667ddbd0f2ab011`, applies the reviewed compatibility
patch, registers all Live sources, runs the API/pagination contract checks, and
builds and uploads `Bilibili-NEXT-Live-unsigned.ipa`. The device-tested player
implementation is retained during the discovery work.

The fixtures under `Tests/Fixtures` are reduced public API captures for tests;
they are never bundled as live recommendations. No account cookies or credentials
are required or committed.
