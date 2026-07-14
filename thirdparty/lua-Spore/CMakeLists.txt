# Build in source tree.
set(BINARY_DIR ${SOURCE_DIR})

# framagit.org unreachable in this env; use a local git mirror of the luarocks
# 0.4.2 source (patch dropped — it only adds JSON content-type detection, N/A here).
append_install_commands(INSTALL_CMD src/Spore.lua DESTINATION common)
append_tree_install_commands(INSTALL_CMD src/Spore common/Spore)

external_project(
    DOWNLOAD GIT 0.4.2
    file:///tmp/claude-1000/-home-leecming-python-obook5/cba147ef-10af-422a-a8c3-576e827d19ff/scratchpad/spore-extract/lua-Spore-0.4.2
    INSTALL_COMMAND ${INSTALL_CMD}
)
