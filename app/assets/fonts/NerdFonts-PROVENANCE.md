# Bundled Nerd Fonts provenance

- Upstream: Nerd Fonts
- Release: `v3.5.1`
- Release page: <https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1>
- Artifact: <https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.zip>
- Artifact SHA-256: `fdca3682534f6f65e1ccb2345b0362ccf67d9b8eca7c8025330946e93e2473bc`
- Bundled file: `SymbolsNerdFontMono-Regular.ttf`
- Original file SHA-256: `fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749`
- Bundled subset SHA-256: `a6de4cfc8a01d6e1271370e35591e23e696c84c52e36929b55d719916ada6b08`

The bundled font contains U+F0140, the private-use dropdown chevron used by maintained QML, plus the required notdef glyph. Its family is renamed to `Magpie Symbols`. Regenerate it with Python and `fonttools==4.60.1` using `python app/scripts/subset-icon-font.py /path/to/upstream/SymbolsNerdFontMono-Regular.ttf`; the script verifies the original font hash before writing the subset. The native resource test checks the repository file-size limit and covers every literal private-use glyph in maintained QML and JavaScript. Add any future icon codepoints to the script before regenerating.

`NerdFonts-LICENSE` is byte-for-byte identical to the archive's `LICENSE`, while `NerdFonts-README.md` preserves its content with trailing blank lines normalized.

The `licenses/` directory preserves the tagged Nerd Fonts v3.5.1 glyph-source
inventory and the license files stored beside the incorporated glyph sets.
`Apache-2.0.txt` is the full license text linked by the tagged Material Design
license notice.
