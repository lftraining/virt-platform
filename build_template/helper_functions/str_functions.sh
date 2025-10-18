#!/bin/bash
##############################################################################
# Written by: John Bonesio
# Licensed under the GPLv2
#
# helper functions to operate on strings
#


str_is_present() { echo "str functions present"; }

###
# str_first_field <str> [separator char (optional)]
#
# 'str_first_field' prints the first field of a string delimited by a given
# separator.
#
# if no separator is given, space is assumed.
#
str_first_field() {
        local str="$1" sep=${2:-' '}

	# remove all text after the last separator
        echo "${str%%$sep*}"
}


# str_last_field <str> [separator char (optional)]
#
# 'str_last_field' prints the last field of a string delimited by a given
# separator.
#
# if no separator is given, space is assumed
#
str_last_field() {
        local str="$1" sep=${2:-' '}

	# remove all text before the last separator
        echo "${str##*$sep}"
}

###
# str_shift <str> [separator char (optional)]
#
# 'str_shift' prints the given string without the first field, delimited by a
# given separator.
#
# if no separator is given, space is assumed
#
str_shift() {
        local str="$1" sep=${2:-' '} result

	# remove all text before the first separator
        result="${str#*$sep}"
	# if no separator was found...
        if [[ "$result" == "$str" ]]; then
                result=""
        fi
        echo "$result"
}

###
# str_rshift <str> [separator char (optional)]
#
# 'str_rshift' prints the given string without the last field, delimited by a
# given separator.
#
# if no separator is given, space is assumed.
str_rshift() {
        local str="$1" sep=${2:-' '} result

	# remove all text after the last separator
        result="${str%$sep*}"
	# if no separator was found...
        if [[ "$result" == "$str" ]]; then
                result=""
        fi
        echo "$result"
}

###
# str_append <str1> <str2>  [separator char (optional)]
#
# 'str_append' appends two strings with the separator (or a space) in between.
# if str1 is empty the separator is omitted.
#
str_append() {
	str="$1" app="$2" sep=${3:-' '} 

	echo "${str:+$str$sep}${app}"
}

###
# str_is_url <str>
#
# 'str_is_url' prints 'true' if the string is a web url.
#
str_is_url() {
	local tmp_str="$1"
	if [[ "$tmp_str" =~ ^http ]]; then
		echo "true"
	else
		echo ""
	fi
}

##
# the spinner API below allow a command line pacifier to be presented on the
# command line. This pacifier is a spinning dial made of various angled line
# characters.
#
# spiiner_start() - reset the spinner
# spiiner_delay() - (optional) set the delay between spinner prints
# spiiner_print_next() - print the next spinner character
##

_spidx=''
_spinner_text='\|/-\|/-'
_spinner_delay='0.25'

###
# spinner_start
#
# 'spinner_start' resets the spinner index to be beginning
#
spinner_start() { _spidx=''; }

###
# spinner_delay <seconds>
#
# 'spinner_delay' sets the spinner delay to an amount of time in seconds or
# fractions of a second.
#
# If not set, the default delay of 0.25 is used .
#
spinner_delay() { _spinner_delay="$1"; }

###
# spinner_print_next
#
# 'spinner_print_next' prints the next spinner character erasing the previous one.
#
# For the spinner to work this routine should be called in a loop
#
spinner_print_next() {
	if [[ -n "$_spidx" ]]; then
		printf "\b%c" ${_spinner_text:$_spidx:1}
	else
		printf "%c" ${_spinner_text:$_spidx:1}
	fi
	sleep "$_spinner_delay"
	(( _spidx++ ))

	if [[ -z "${_spinner_text:$_spidx:1}" ]]; then
		_spidx=0
	fi
}

##
# in case this is run
if [[ "$0" == 'str_functions.sh' ]]; then
	echo "This script doesn't do anything on its own"
	echo "It's meant only to be included in other scripts"
fi
