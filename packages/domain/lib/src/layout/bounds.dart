/// Resource bounds of the working-set document (design D7, D8).
library;

/// Maximum number of tab groups in a document.
const int maxTabGroups = 16;

/// Maximum number of tabs in a document.
const int maxTabs = 128;

/// Maximum encoded size of a tab's `state` object, in UTF-8 bytes.
const int maxTabStateBytes = 4096;

/// Maximum encoded size of the whole document, in UTF-8 bytes (256 KiB).
const int maxDocumentBytes = 262144;

/// Maximum UTF-8 size of ids (tab, group, split, workspace refs) and kinds.
const int maxIdBytes = 64;

/// Maximum UTF-8 size of a tab's `item`.
const int maxItemBytes = 4096;

/// Smallest allowed split ratio.
const double minSplitRatio = 0.1;

/// Largest allowed split ratio.
const double maxSplitRatio = 0.9;

/// The only supported document format.
const int layoutFormat = 1;
