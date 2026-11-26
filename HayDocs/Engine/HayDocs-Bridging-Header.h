// C interface of the document engine (engine/src/lib.rs, built as libhaydocs_engine.a).
#ifndef HAYDOCS_BRIDGING_HEADER_H
#define HAYDOCS_BRIDGING_HEADER_H

#include <stdint.h>

/// Add font files: a JSON array of paths. Returns the number of faces added (negative on error).
int32_t hd_add_fonts(const char *paths_json);

/// Convert a document to PDF. The request and the answer are JSON; free the answer with hd_free.
char *hd_convert(const char *request_json);

/// Save a document as Word (.docx) or OpenDocument (.odt) with the Pencil drawings over its pages.
/// The request and the answer are JSON; free the answer with hd_free.
char *hd_export(const char *request_json);

void hd_free(char *s);

/// The engine's version (static, don't free).
const char *hd_version(void);

#endif
