#!/usr/bin/env python
# coding=utf-8

from __future__ import print_function

import math
import os
import sys

from get_resolution import get_resolution


def get_zoom_offset(width, height, approximate_zoom):
    return len([
        x for x in range(approximate_zoom)
        if (height / (2**(x + 1))) >= 1 and (width / (2**(x + 1))) >= 1
    ])


def get_zoom(input):
    return min(22,
               int(
                   math.ceil(
                       math.log((2 * math.pi * 6378137) / (
                           get_resolution(input) * 256)) / math.log(2))))


if __name__ == "__main__":
    if len(sys.argv) == 1:
        print(
            "usage: {} <input>".format(os.path.basename(sys.argv[0])),
            file=sys.stderr)
        exit(1)

    input = sys.argv[1]
    try:
        print(get_zoom(input))
    except IOError:
        print("Unable to open '{}'.".format(input), file=sys.stderr)
        exit(1)
