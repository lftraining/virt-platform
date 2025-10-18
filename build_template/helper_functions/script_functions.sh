#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# helper functions to run other scripts
#

#######
# General script helper functions
#

_emit_file=''
###
# emit_set_file <file path>
#
# 'emit_set_file' will specify the path where commands are emitted.
#
emit_set_file() {
}

###
# emit <command with args>
#
# 'emit' will either execute the fuction outright, or
# append the command to another file to be (re-)run later.
#
# If the emit file is not speciied, 'emit' will just execute the commands in
# place.
#
# The emit file is set with a call to emit_set_file().
#
emit() {
	if [[ -n "$_emit_file" ]]; then
		echo "$@" >> $_emit_file
	else
		"$@"
	fi
}
