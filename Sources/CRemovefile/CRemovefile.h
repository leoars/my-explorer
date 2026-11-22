// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <removefile.h>
#include <stddef.h>

static inline int explorer_remove_tree_at(int parent, const char *name) {
    return removefileat(parent, name, NULL, REMOVEFILE_RECURSIVE);
}
