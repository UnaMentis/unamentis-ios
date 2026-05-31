# Bundled Content Licenses and Provenance

This document records the source and licensing of third-party content shipped inside the app bundle. It exists for App Store content-rights compliance and open-source transparency. Update it whenever bundled content changes.

## Knowledge Bowl question bank

File: `UnaMentis/Resources/kb-sample-questions.json`

Each question carries a per-item `source` attribution. The questions come from two families:

| Source family | Origin | License |
|---------------|--------|---------|
| DOE Science Bowl | U.S. Department of Energy National Science Bowl official question sets | Public domain (work of the U.S. federal government, not subject to copyright under 17 U.S.C. 105) |
| OpenTriviaQA | The Open Trivia Database community question set | Creative Commons Attribution-ShareAlike 4.0 (CC BY-SA 4.0) |

Attribution for the CC BY-SA 4.0 questions is preserved in each item's `source` field. Any redistribution of derived question sets must retain attribution and share-alike terms.

## Curriculum reference images

Directory: `UnaMentis/Resources/CurriculumAssets/`

These are reference images used by sample curriculum visual assets:

| File | Depicts | Status |
|------|---------|--------|
| `img-mona-lisa.jpg` | Leonardo da Vinci, Mona Lisa (c. 1503) | Underlying work is public domain (pre-1900). Faithful photographic reproductions of 2D public-domain works are not separately copyrightable in the U.S. |
| `img-last-supper.jpg` | Leonardo da Vinci, The Last Supper (c. 1495) | Public domain underlying work, as above |
| `ref-school-of-athens.jpg` | Raphael, The School of Athens (c. 1510) | Public domain underlying work, as above |
| `ref-botticelli-birth-venus.jpg` | Sandro Botticelli, The Birth of Venus (c. 1485) | Public domain underlying work, as above |
| `ref-durer-engravings.jpg` | Albrecht Durer engravings (early 1500s) | Public domain underlying work, as above |
| `img-us-capitol.jpg` | United States Capitol building | Provenance to confirm: building is public; the specific photograph's source and license need to be recorded before public release |
| `ref-museum-virtual-tours.jpg` | Museum virtual tours reference image | Provenance to confirm: source and license need to be recorded before public release |

## Action items before public release

1. Confirm and record the photographer/source and license for `img-us-capitol.jpg` and `ref-museum-virtual-tours.jpg`, or replace them with clearly public-domain or self-produced assets.
2. Keep this file in sync with any added or changed bundled content.
