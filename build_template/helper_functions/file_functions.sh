#!/bin/bash

#######
# General file helper functions
#

SED="sed -E"
MV="mv"
RM="rm"

file_is_present() { echo "file functions present"; }

###
# basename_no_ext <file name str>
#
# 'basename_no_ext' prints the basename of the given file name without the
# extension.
basename_no_ext() {
	local fname="$1" local bname_w_ext=$(basename "$1")

	echo "${bname_w_ext%.*}"
}

###
# file_len <file>
#
# 'file_len' prints the number of lines in the given file
#
file_len() {
	local file="$1"

	echo "$(wc -l < $file)"
}


###
# file_keep_tmps
#
# 'file_keep_tmps' sets operations to leave temporary files, not delete them.
#
file_keep_tmps() {
	MV="cp"
	RM=":"
}

tcount=1
###
# file_insert_at <file> <text> {line number} {tmp file name}
#
# 'file_insert_at' inserts the given text (single or multiline) into the given
# file at the provided line number.
#
# if the line number is not given, the text is appended to the file
#
# Also the name to use for temporary files can be provided for debugging.
#
file_insert_at() {
	local file="$1" text="$2" lineno="$3" tmp_nam="${4:-$tcount}" last_lines

	n_lines=$(file_len $file)
	if [[ -z "$lineno" ]]; then lineno=$n_lines; fi
	last_lines=$(( $n_lines - $lineno))

	(head -n $lineno $file; echo -e "$text"; tail -n $last_lines $file) > $tmp_nam
	$MV "$tmp_nam" "$file"
	(( tcount++ ))
}

###
# file_add_after <file> <text> <after regex>
#
# 'file_add_after' inserts the given text (single or multiline) into the given
# file on the line after the given regex
#
# If the after regex is not given, the text is appended to the file
#
file_add_after() {
        local file=${1:?} line=${2:?} after=${3:-$} lineno next_lineno

        [[ -e $file ]] || touch "$file"
        if ! grep -q "^$line$" "$file" ; then
		lineno="$(sed -n ${after}= $file)"

		if [[ -z $lineno ]]; then
			lineno=$(file_len $file)
			echo "lineno: set to eof: ${after}"
		fi

		file_insert_at $file "${line}" $lineno "$tcount"
        fi
}

###
# file_add_after_at_section_end <file> <text> <after regex>
#
# 'file_add_after_at_section_end' inserts the given text (single or multiline)
# file at the end of a section heading specified by the given regex. 
#
# 'file_add_after_at_section_end' requires that section headings begin on
# column 1, and end with a colon (:). So the regex should be in the form:
#   /<heading>:/
#
file_add_after_at_section_end() {
        local file=${1:?} line=${2:?} after=${3:-$}
	local lineno next_lineno lineno_next_sect match_txt 

        [[ -e $file ]] || touch "$file"
	#
	# There might be a slick one-liner, but here...
	#
	# get the line number of the 'after' text
	# search for the next section (has to be on column 1 ending with ':') and ...
	# insert new text right before that next section, or at the end of the
	# file if there's no next section
	#
	lineno="$(sed -n ${after}= $file)"

	if [[ -n $lineno ]]; then
		next_lineno=$(($lineno + 1))

		match_txt=$(tail -n +$next_lineno $file | grep -n "^[[:alpha:]][[:alpha:]]*:$")
		if [[ -n $match_txt ]]; then
			lineno_next_sect="${match_txt%%:*}"
			lineno_next_sect=$(( $lineno_next_sect + $lineno ))
		fi

		echo "lineno_next_sect: $lineno_next_sect"

		if [[ -z $lineno_next_sect ]]; then
			lineno_next_sect=$(file_len $file)
		fi
		file_insert_at $file "${line}" $lineno_next_sect "$tcount"
	fi
}

###
# file_find_newest <path_file_spec>
#
# 'file_find_newest' prints the newest file that matches the given
# path_file_spec
#
file_find_newest() {
	local path_and_spec="$1"

	echo $(ls -t --time=birth $1 | head -1)
}
