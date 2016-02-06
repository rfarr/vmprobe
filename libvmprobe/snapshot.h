#pragma once

#include <string>
#include <vector>
#include <functional>
#include <stdexcept>

#include "bitfield.h"
#include "binformat.h"


namespace vmprobe { namespace cache { namespace snapshot {


/*

SNAPSHOT_V1:

"VMP" magic bytes
VI: type
VI: snapshot pagesize in bytes (0 special-cased as 4096)
N>=0 records:
  VI: record size in bytes, not including this size
  VI: flags
  VI: filename size in bytes
  filename
  VI: file size in bytes
  VI: bitfield buckets
  bitfield (0 = non-resident, 1 = resident)

*/




class element {
  public:
    char *filename;
    size_t filename_len;
    uint64_t file_size;
    vmprobe::cache::bitfield bf;
};


class builder : public vmprobe::cache::binformat::builder {
  public:
    builder();

    void crawl(std::string path);
    void apply_delta(char *snapshot_ptr, size_t snapshot_len, char *delta_ptr, size_t delta_len);

  private:
    void add_element(element &elem);
};




using parser_element_handler_cb = std::function<void(element &elem)>;


class parser : public vmprobe::cache::binformat::parser {
  public:
    parser(char *ptr, size_t len);

    void process(parser_element_handler_cb cb);

    uint64_t snapshot_pagesize;
    uint64_t flags;

  private:
    element *next();

    std::string curr_filename;
    element curr_elem;
};

void restore(char *ptr, size_t len);








}}}
