# atom_filter
[![Hex.pm](https://img.shields.io/hexpm/v/atom_filter.svg)](https://hex.pm/packages/atom_filter)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/atom_filter)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE.md)

em_filter agent for Atom feeds.

Reads a list of Atom feed URLs from `atom_config.json`, fetches each feed,
and returns entries whose title, link or summary matches the search query.

Handles Atom-specific structure: `<entry>` elements, `<link href="..."/>` attributes,
and `<summary>` / `<content>` bodies — distinct from RSS `<item>` / `<link>` / `<description>`.

## Setup

Rename `atom_config.json.sample` to `atom_config.json` and fill in your feed URLs:

```json
{
    "atom_feeds": [
        "https://example.com/feed.atom",
        "https://another.com/feed.xml"
    ]
}
```

## Usage

Add `atom_filter` to your dependencies, then start it as an OTP application.
It registers itself with `em_disco` automatically on startup.

For a site-specific filter, create a wrapper application that copies its own
`priv/atom_config.json` to the working directory before starting `atom_filter`.
See `linuxfr_atom_filter` for a concrete example.
