cmake_minimum_required(VERSION 3.22.1)
project(sdi_storage LANGUAGES C)
add_library(sdi_storage SHARED room_atomic_publish.c)
set_target_properties(sdi_storage PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_compile_options(sdi_storage PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
# Compatible ELF segment alignment for both 4 KiB and 16 KiB page-size devices.
target_link_options(sdi_storage PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
