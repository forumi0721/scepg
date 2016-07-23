#!/usr/bin/env bash

echo_white() {
	echo $'\e[01;0m'"${1}"$'\e[0m'"${2}"
}

echo_gray() {
	echo $'\e[01;30m'"${1}"$'\e[0m'"${2}"
}

echo_red() {
	echo $'\e[01;31m'"${1}"$'\e[0m'"${2}"
}

echo_green() {
	echo $'\e[01;32m'"${1}"$'\e[0m'"${2}"
}

echo_yellow() {
	echo $'\e[01;33m'"${1}"$'\e[0m'"${2}"
}

echo_blue() {
	echo $'\e[01;34m'"${1}"$'\e[0m'"${2}"
}

echo_violet() {
	echo $'\e[01;35m'"${1}"$'\e[0m '"${2}"
}

#Variables
DEBUG=0
IS_MAC=N
if [ "$(uname -s)" = "Darwin" ]; then
	IS_MAC=Y
	SED="gsed"
else
	SED="sed"
fi
TV_CHANNEL_CONF="tvchannel.conf"
WORKING_DIR=
if [ -d "/dev/shm" -a -w "/dev/shm" ]; then
	if [ "${DEBUG}" = 0 ] ; then
		WORKING_DIR="/dev/shm/scepg_${USER}"
	else
		WORKING_DIR=./working
	fi
else
	WORKING_DIR=./working
fi
COUNT="${WORKING_DIR}/count"
BASE_URL_UPLUS='http://www.uplus.co.kr/css/chgi/chgi/RetrieveTvSchedule.hpi?chnlCd={channelId}&evntCmpYmd={date_ymd}'
BASE_URL_NAVER='http://tvguide.naver.com/program/multiChannel.nhn?broadcastType={broadcast_type}&channelGroup={channel_group}&date={date_ymd}'
BASE_URL_EPG='http://epg.co.kr/php/guide/schedule_day_on.php?search_top_channel_group={top_channel_group}&old_top_channel_group={top_channel_group}&search_sub_channel_group={sub_channel_group}&old_sub_channel_group={sub_channel_group}&ymd={date}&{channel}'
BASE_URL_EPG_CHECKCHANNEL='checkchannel%5B{channel_id}%5D={channel_no}'
WORKING_UPLUS="${WORKING_DIR}/working_uplus"
WORKING_NAVER="${WORKING_DIR}/working_naver"
WORKING_EPG="${WORKING_DIR}/working_epg"
OUTPUT_FILE="${WORKING_DIR}/xmltv.xml"
XMLTV_FILE="./xmltv.xml.gz"
TIMESTAMP=".timestamp"
DOWNLOAD_DATE="3"
D="^#^"

fn_validation() {
	if [ ! -e "${TV_CHANNEL_CONF}" ]; then
		echo "Cannot find ${TV_CHANNEL_CONF}"
		exit 1
	fi
	if [ -z "$(which "${SED}")" ]; then
		echo_red " -> " "Cannot found "${SED}""
		if [ "${IS_MAC}" = "Y" ]; then
			echo_red "    " "Pleas install brew gnu-sed package"
		fi
		exit 1
	fi
	if [ -z "$(which flock)" ]; then
		echo_red " -> " "Cannot found flock"
		if [ "${IS_MAC}" = "Y" ]; then
			echo_red "    " "Pleass install flock package"
			echo_red "    " " # brew tap discoteq/discoteq"
			echo_red "    " " # brew install flock"
		fi
		exit 1
	fi
	mkdir -p "${WORKING_DIR}" &> /dev/null
	if [ "${?}" != "0" ]; then
		echo_red " -> " "Cannot make working directory(${WORKING_DIR})"
		exit 1
	fi
	if [ ! -w "${WORKING_DIR}" -o ! -r "${WORKING_DIR}" ]; then
		echo_red " -> " "Cannot access working directory(${WORKING_DIR})"
		exit 1
	fi
	if [ "${DEBUG}" = "0" -a -e "${TIMESTAMP}" -a "${OUTPUT_FILE}" ]; then
		if [ "$(wc -l < "${TIMESTAMP}")" = "3" ]; then
			local md5sum_prev="$(head -n 1 "${TIMESTAMP}")"
			local datetime_prev="$("${SED}" -n "2,1p" "${TIMESTAMP}")"

			if [ ! -z "${md5sum_prev}" -a ! -z "${datetime_prev}" ]; then
				local md5sum="$(fn_md5 "${TV_CHANNEL_CONF}")"
				local datetime_prev_s="$(date -d "${datetime_prev}" +%s)"
				local datetime_s="$(date +%s)"

				if [ "${md5sum}" = "${md5sum_prev}" -a $((datetime_s - $datetime_prev_s)) -lt 3600 ]; then
					echo_yellow "Alread up-to date ($(date -d "${datetime_prev}" "+%F %T"))"
					exit 1
				fi
			fi
		fi
	fi
}

fn_preproc() {
	fn_md5 "${TV_CHANNEL_CONF}" > "${TIMESTAMP}"
	date +"%F %T" >> "${TIMESTAMP}"

	if [ "${DEBUG}" = "0" ]; then
		rm -rf "${WORKING_DIR}"
	fi
	mkdir -p "${WORKING_DIR}" &> /dev/null
	if [ "${?}" != "0" ]; then
		echo "Cannot make working directory(${WORKING_DIR})"
		exit 1
	fi
	touch "${OUTPUT_FILE}"

	fn_count_reset
}

fn_md5() {
	if [ "${IS_MAC}" = "Y" ]; then
		md5 "${1}" | "${SED}" -e "s/^.*= \(.*\)$/\1/g"
	else
		md5sum "${1}" | "${SED}" -e "s/^\(.*\)[[:space:]]\+.*$/\1/g"
	fi
}

fn_count_reset() {
	(
		while ! flock -w 10 100
		do
			sleep 0.1
		done
		echo 1 > "${COUNT}"
	) 100>"${COUNT}.lock"
}

fn_count_get() {
	(
		while ! flock -w 10 200
		do
			sleep 0.1
		done
		local count=$(cat "${COUNT}")
		echo "$((count + 1))" > "${COUNT}"
		echo "${count}"
	) 200>"${COUNT}.lock"
}

fn_file_write() {
	(
		while ! flock -w 10 300
		do
			sleep 0.1
		done
		if [ -z "${2}" ]; then
			while read -r data
			do
				echo "${data}" >> "${1}"
			done
		else
			echo "${2}" >> "${1}"
		fi
	) 300>"${1}.lock"
}

fn_download_uplus() {
	local channels="$("${SED}" -e "/^[^#].*:U,.*$/!d" "${TV_CHANNEL_CONF}")"
	if [ -z "${channels}" ]; then
		return
	fi

	local download_list=()

	echo_blue " -> " "Generate Download URL(uplus)"

	local line=
	while read -r line
   	do
		local channel_no="$("${SED}" -e "s/^\(.*\),\(.*\):U,\(.*\),.*$/\1/g" <<< "${line}")"
		local channel_name="$("${SED}" -e "s/^\(.*\),\(.*\):U,\(.*\),.*$/\2/g" <<< "${line}")"
		local channel_id="$("${SED}" -e "s/^\(.*\),\(.*\):U,\(.*\),.*$/\3/g" <<< "${line}")"

		local url="${BASE_URL_UPLUS}"
		url="${url//\{channelId\}/${channel_id}}"
		download_list+=("$(echo "${channel_no},${channel_name},${url}")")
	done <<< "${channels}"

	echo_blue " -> " "Done."

	echo_blue " -> " "Start Download(uplus)"

	cat /dev/null > "${WORKING_UPLUS}"

	local day=
	for day in $(seq 0 $((DOWNLOAD_DATE - 1)))
	do
		fn_count_reset

		local date_ymd="$(date +%Y%m%d -d "${day} days")"
		local date_display="$(date +%Y-%m-%d -d "${day} days")"

		local download_length=${#download_list[@]}
		local download_count=
		for download_count in $(seq 0 $((download_length - 1)))
		do
			while [ $(jobs -rp | wc -l) -ge 16 ]
			do
				sleep 0.1
			done
			job &> /dev/null

			echo -ne " -> ${date_display} $(fn_count_get)/${#download_list[@]}\033[0K\r"
			local url="${download_list[${download_count}]}"
			local url1="$("${SED}" -e "s/^\(.*\),\(.*\),\(.*\)$/\1/g" <<< "${url}")"
			local url2="$("${SED}" -e "s/^\(.*\),\(.*\),\(.*\)$/\2/g" <<< "${url}")"
			local url3="$("${SED}" -e "s/^\(.*\),\(.*\),\(.*\)$/\3/g" <<< "${url}")"

			fn_download_uplus_thread "${url3/\{date_ymd\}/${date_ymd}}" "${url1}" "${url2}" "${date_ymd}" &
		done

		wait

		echo
	done

	echo_blue " -> " "Done."
}

fn_download_uplus_thread() {
	local url="${1}"
	local url1="${2}"
	local url2="${3}"
	local date_ymd="${4}"
	local html="$(curl -s "${url}" | iconv -c -f cp949 -t utf-8)"
	if [ -z "$(grep '조회내역이 없습니다.' <<< "${html}")" ]; then
		"${SED}" -e "/datatype_head/,/<tbody>/d" -e "/<\/tbody>/,\$d" -e "s/^\s\+//g" <<< "${html}" | tr -d "\r" | "${SED}" -e "/^$/d" -e "s/^.*txtcon_grade_[[:alpha:]]\+\([[:digit:]]\+\).*$/\1/g" -e "s/^.*txtcon_all.*$//g" -e "/txtcon/d" -e "s/<td>\([[:digit:]]\+\):\([[:digit:]]\+\)<\/td>/${url1}${D}'${url2}'${D}${date_ymd}\1\2/g" -e "s/^<td class=\"title\">\(.*\)$/'\1'/g" -e "/<td>\|<\/td>/d" | "${SED}" -e "/<tr>.*/{N;N;N;N; s/\n/${D}/g}" | "${SED}" -e "s/^<tr>${D}//g" -e "/<\/tr>/d" | "${SED}" -e "s/&/&amp;/g" -e "s/>/\&gt;/g" -e "s/</\&lt;/g" -e "s/%/\&#37;/g" -e "s/&amp;amp;/\&amp;/g" -e "s/&amp;gt;/\&gt;/g" -e "s/&amp;lt;/\&lt;/g" -e "s/&amp;#37;/\&#37;/g" | fn_file_write "${WORKING_UPLUS}"
	fi
}

fn_download_naver() {
	local channels="$("${SED}" -e "/^[^#].*,.*:N,.*,.*,.*,.*$/!d" "${TV_CHANNEL_CONF}")"
	if [ -z "${channels}" ]; then
		return
	fi

	local download_list=()

	echo_blue " -> " "Generate Download URL(naver)"

	local channel_filter="$("${SED}" -e "s/^[^#].*,.*:N,\(.*\),.*,\(.*\),.*$/\1,\2,/g" <<< "${channels}" | "${SED}" -e ":a;N;\$!ba;s/\n/\\\|/g")"

	local line=
	while read -r line
   	do
		local broadcast_type="$("${SED}" -e "s/^\(.*\),.*$/\1/g" <<< "${line}")"
		local channel_group="$("${SED}" -e "s/^.*,\(.*\)$/\1/g" <<< "${line}")"

		local url="${BASE_URL_NAVER}"
		url="${url//\{broadcast_type\}/${broadcast_type}}"
		url="${url//\{channel_group\}/${channel_group}}"
		download_list+=("${url}")
	done <<< "$("${SED}" -e "s/^.*,.*:N,\(.*,.*\),.*,.*$/\1/g" <<< "${channels}" | sort -u)"

	echo_blue " -> " "Done."

	echo_blue " -> " "Start Download(naver)"

	cat /dev/null > "${WORKING_NAVER}"

	local day=
	for day in $(seq 0 $((DOWNLOAD_DATE - 1)))
	do
		fn_count_reset

		local date_ymd="$(date +%Y%m%d -d "${day} days")"
		local date_display="$(date +%Y-%m-%d -d "${day} days")"

		for url in ${download_list[@]}
		do
			while [ $(jobs -rp | wc -l) -ge 16 ]
			do
				sleep 0.1
			done
			job &> /dev/null

			echo -ne " -> ${date_display} $(fn_count_get)/${#download_list[@]}\033[0K\r"
			curl -s "${url/\{date_ymd\}/${date_ymd}}" | "${SED}" -e "/[[:space:]]*\"broadcastType\" :\|[[:space:]]*\"channelId\" :\|[[:space:]]*\"programList\" :/!d" -e "s/^[[:space:]]\+//g" | "${SED}" -e "/^\"broadcastType\".*/ {N;N; s/\"broadcastType\" : \([[:digit:]]*\),.*\"channelId\" : \([[:digit:]]*\),.*\(\"programList\" :.*\)$/\1,\2,\3/g}" | "${SED}" -e "/${channel_filter}/!d" | "${SED}" -e "s/&/&amp;/g" -e "s/>/\&gt;/g" -e "s/</\&lt;/g" -e "s/%/\&#37;/g" | fn_file_write "${WORKING_NAVER}" &
		done

		wait

		echo
	done

	echo_blue " -> " "Done."
}

fn_download_epg() {
	local channels="$("${SED}" -e "/^[^#].*,.*:E,.*,.*,.*,.*$/!d" "${TV_CHANNEL_CONF}")"
	if [ -z "${channels}" ]; then
		return
	fi

	local download_list=()

	echo_blue " -> " "Generate Download URL(epg)"

	local line=
	while read -r line
	do
		local top_channel_group="$("${SED}" -e "s/^\(.*\),.*$/\1/g" <<< "${line}")"
		local sub_channel_group="$("${SED}" -e "s/^.*,\(.*\)$/\1/g" <<< "${line}")"
		local checkchannel=
		local loop_seq=1
		local line=
		while read -r channel
	   	do
			local channel_id="$("${SED}" -e "s/^[^#].*:E,.*,.*,\(.*\),.*$/\1/g" <<< "${channel}")"
			local channel_no="$("${SED}" -e "s/^\([^#].*\),.*:E,.*,.*,.*,.*$/\1/g" <<< "${channel}")"
			local checkchannel_curr="${BASE_URL_EPG_CHECKCHANNEL}"
			checkchannel_curr="${checkchannel_curr//\{channel_id\}/${channel_id}}"
			checkchannel_curr="${checkchannel_curr//\{channel_no\}/${channel_no}}"
			checkchannel+="${checkchannel_curr}&"

			if [ "$((loop_seq % 5))" = "0" ]; then
				local url="${BASE_URL_EPG}"
				url="${url//\{top_channel_group\}/${top_channel_group}}"
				url="${url//\{sub_channel_group\}/${sub_channel_group}}"
				url="${url//\{channel\}/${checkchannel}}"
				download_list+=("${url}")
				checkchannel=""
				loop_seq=0
			fi

			loop_seq=$((loop_seq + 1))
		done <<< "$("${SED}" -e "/^[^#].*,.*:E,${top_channel_group},${sub_channel_group},.*,.*/!d" <<< "${channels}")"

		if [ ! -z "${checkchannel}" ]; then
			local url="${BASE_URL_EPG}"
			url="${url//\{top_channel_group\}/${top_channel_group}}"
			url="${url//\{sub_channel_group\}/${sub_channel_group}}"
			url="${url//\{channel\}/${checkchannel}}"
			download_list+=("${url}")
			checkchannel=""
		fi
	done <<< "$("${SED}" -e "s/^[^#].*,.*:E,\(.*,.*\),.*,.*$/\1/g" <<< "${channels}" | sort -u)"

	echo_blue " -> " "Done."

	echo_blue " -> " "Start Download(epg)"

	cat /dev/null > "${WORKING_EPG}"
	local year="$(date +%Y)"

	local day=
	for day in $(seq 0 $((DOWNLOAD_DATE - 1)))
	do
		fn_count_reset

		local date="$(date +%Y-%m-%d -d "${day} days")"
		local date_progress="$(date +%Y-%m-%d -d "${day} days")"

		for url in ${download_list[@]}
		do
			while [ $(jobs -rp | wc -l) -ge 16 ]
			do
				sleep 0.1
			done
			job &> /dev/null

			echo -ne " -> ${date_progress} $(fn_count_get)/${#download_list[@]}\033[0K\r"
			#'channel_no','title','start','end','category'
			#Todo : New year
			echo "${url/\{date\}/${date}}"
			curl -s "${url/\{date\}/${date}}" | iconv -c -f cp949 -t utf-8 |  "${SED}" -e "/JavaScript:ViewContent/!d" -e "s/JavaScript:ViewContent/\n/g" | "${SED}" -e "/onMouseOver=\"Preview(/!d" | "${SED}" -e "s/.*onMouseOver=\"Preview(\(.*\))\" >.*$/\1/g" -e "s/<br>//g" -e "s/\\\'/'/g" | "${SED}" -e "s/^'.*',\('.*'\),\('.*'\),\('.*'\),\('.*'\),'.*','.*'/\2${D}\1${D}\3${D}\4/g" -e "s/'\([[:digit:]]\+\/[[:digit:]]\+\) \([AP]M\) \([[:digit:]]\+:[[:digit:]]\+\)~\([[:digit:]]\+\/[[:digit:]]\+\) \([AP]M\) \([[:digit:]]\+:[[:digit:]]\+\)'/'${year}\/\1 \3 \2'${D}'${year}\/\4 \6 \5'/g" | fn_file_write "${WORKING_EPG}" &
		done

		wait

		echo

	done

	wait

	echo_blue " -> " "Done."
}

fn_download() {
	echo_green "==> " "Start Download"

	fn_download_uplus

	fn_download_naver

	fn_download_epg

	echo_green "==> " "Done."
	echo
}

fn_generate_xml_header() {
	echo_blue " -> " "Generate Header"

	local result=
	read -r -d "" result << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">

<tv source-info-name="stonecold.kr" generator-info-name="forumi0721" generator-info-url="mailto:forumi0721@gmail.com">
EOF
	fn_file_write "${OUTPUT_FILE}" "${result}"

	echo_blue " -> " "Done."
}

fn_generate_xml_channel() {
	echo_blue " -> " "Generate Channel"

	fn_count_reset

	local channels="$("${SED}" -e "/^\([^#][^,]*,[^:]*\).*$/!d" -e "/^#/d" -e "s/^\([^,]*,[^:]*\).*$/\1/g" "${TV_CHANNEL_CONF}")"
	local channels_count="$(wc -l <<< "${channels}")"

	local line=
	while read -r line
	do
		echo -ne " -> $(fn_count_get)/${channels_count}\033[0K\r"
		local channel_no="$("${SED}" -e "s/^\(.*\),.*$/\1/g" <<< "${line}")"
		local channel_name="$("${SED}" -e "s/^.*,\(.*\)/\1/g" -e "s/&/&amp;/g" -e "s/>/\&gt;/g" -e "s/</\&lt;/g" -e "s/%/\&#37;/g" -e "s/&amp;amp;/\&amp;/g" -e "s/&amp;gt;/\&gt;/g" -e "s/&amp;lt;/\&lt;/g" -e "s/&amp;#37;/\&#37;/g" <<< "${line}")"

		if [ -z "${channel_no}" -o -z "${channel_name}" ]; then
			continue
		fi

		local result=
		read -r -d "" result << EOF
<channel id="I${channel_no}.stonecold.kr">
	<display-name>${channel_no} ${channel_name}</display-name>
	<display-name>${channel_no}</display-name>
	<display-name>${channel_name}</display-name>
</channel>
EOF
		fn_file_write "${OUTPUT_FILE}" "${result}"
	done <<< "${channels}"

	echo
	echo_blue " -> " "Done."
}

fn_generate_xml_programme_uplus() {
	if [ ! -e "${WORKING_UPLUS}" ]; then
		return
	fi

	local channels=($("${SED}" -e "s/^\(.*\)^#^'.*'^#^.*^#^'.*'^#^.*^#^.*/\1/g" "${WORKING_UPLUS}" | sort -u))
	local total_count="$(wc -l < "${WORKING_UPLUS}")"
	if [ "${total_count}" -le 0 ]; then
		return
	fi

	echo_blue " -> " "Generate Programme(uplus)"

	fn_count_reset

	local ch=
	for ch in ${channels[@]}
	do
		while [ $(jobs -rp | wc -l) -ge 16 ]
		do
			sleep 0.1
		done
		job &> /dev/null

		fn_generate_xml_programme_uplus_thread "${ch}" "$("${SED}" -e "/^${ch}${D}/!d" "${WORKING_UPLUS}")" "${total_count}" &
	done

	wait

	echo
	echo_blue " -> " "Done."

}

fn_generate_xml_programme_uplus_thread() {
	local channel_no="${1}"
	local info="${2}"
	local total_count="${3}"

	local prev_info=

	local line=
	while read -r line
	do
		if [ ! -z "${prev_info}" ]; then
			echo -ne " -> $(fn_count_get)/${total_count}\033[0K\r"

			local title="$("${SED}" -e "s/^.*${D}'.*'${D}.*${D}'\(.*\)'${D}.*${D}.*$/\1/g" <<< "${prev_info}")"

			local episode="$("${SED}" -e "s/^.*(\([[:digit:]]\+회\))/\1/g" <<< "${title}")"
			if [ "${episode}" = "${title}" ]; then
				episode=""
			else
				title="$("${SED}" -e "s/^\(.*\)[[:space:]]*([[:digit:]]\+회)/\1/g" <<< "${title}" | "${SED}" -e "s/[[:space:]]\+$//g")"
			fi

			local subtitle="$("${SED}" -e "s/^.*&lt;\(.*\)&gt;$/\1/g" <<< "${title}")"
			if [ "${subtitle}" = "${title}" ]; then
				subtitle=""
			else
				title="$("${SED}" -e "s/^\(.*\)[[:space:]]*&lt;.*&gt;$/\1/g" <<< "${title}" | "${SED}" -e "s/[[:space:]]\+$//g")"
			fi

			local desc="${title}"
			if [ ! -z "${subtitle}" ]; then
				desc+=" &lt;${subtitle}&gt;"
			fi
			if [ ! -z "${episode}" ]; then
				desc+=" (${episode})"
			fi

			local start="$("${SED}" -e "s/^.*${D}'.*'${D}\(.*\)${D}'.*'${D}.*${D}.*$/\1/g" <<< "${prev_info}")"
			local end="$("${SED}" -e "s/^.*${D}'.*'${D}\(.*\)${D}'.*'${D}.*${D}.*$/\1/g" <<< "${line}")"

			local category="$("${SED}" -e "s/^.*${D}'.*'${D}.*${D}'.*'${D}.*${D}\(.*\)$/\1/g" <<< "${prev_info}")"
			local category_en=
			case ${category//-*/} in
				드라마) #드라마
					category="드라마"
					category_en="Movie / Drama"
					;;
				영화) #영화
					category="영화"
					category_en="Movie / Drama"
					;;
				만화) #만화
					category="만화"
					category_en="Children's / Youth programmes"
					;;
				연예/오락) #연예/오락
					category="연예/오락"
					category_en="Show / Games"
					;;
				스포츠) #스포츠
					category="스포츠"
					category_en="Sports"
					;;
				라이프) #라이프
					category="라이프"
					category_en="Leisure hobbies"
					;;
				공연/음악) #공연/음악
					category="공연/음악"
					category_en="Music / Ballet / Dance"
					;;
				교육) #교육
					category="교육"
					category_en="Education / Science / Factual topics"
					;;
				뉴스/정보) #뉴스/정보
					category="뉴스/정보"
					category_en="News / Current affairs"
					;;
				다큐) #다큐
					category="다큐"
					category_en="Social / Political issues / Economics"
					;;
				예술) #예술
					category="예술"
					category_en="Arts / Culture (without music)"
					;;
				*) #기타
					category=""
					category_en=""
					;;
			esac

			local rating="$("${SED}" -e "s/^.*${D}'.*'${D}.*${D}'.*'${D}\(.*\)${D}.*$/\1/g" <<< "${prev_info}")"

			local result=
			read -r -d "" result << EOF
<programme start="${start} +0900" stop="${end} +0900" channel="I${ch}.stonecold.kr">
	<title lang="ko">${desc}</title>
	<desc lang="ko">${desc}</desc>
	<episode-num system="onscreen">${episode}</episode-num>
	<category lang="en">${category_en}</category>
	<category lang="ko">${category}</category>
	<language>ko</language>
	<rating system="VCHIP">
		<value>${rating}</value>
	</rating>
	<generate-source name="http://www.uplus.co.kr/"/>
</programme>
EOF
			fn_file_write "${OUTPUT_FILE}" "${result}"
		else
			echo -ne " -> $(fn_count_get)/${total_count}\033[0K\r"
		fi
		prev_info="${line}"
	done <<< "${info}"

	return
}

fn_generate_xml_programme_naver() {
	if [ ! -e "${WORKING_NAVER}" ]; then
		return
	fi

	local total_count="$("${SED}" -e "s/scheduleName/scheduleName\n/g" "${WORKING_NAVER}" | "${SED}" -e "/scheduleName/!d" | wc -l)"
	if [ "${total_count}" -le 0 ]; then
		return
	fi

	echo_blue " -> " "Generate Programme(naver)"

	fn_count_reset
	
	local line=
	while read -r line
	do
		local channel_no="$("${SED}" -e "s/^\(.*\),.*:N,.*,.*,.*,.*$/\1/g" <<< "${line}")"
		if [ -z "${channel_no}" -o "${channel_no}" = "${line}" ]; then
			continue
		fi
		local channel_filter="$("${SED}" -e "s/^[^#].*,.*:N,\(.*\),.*,\(.*\),.*$/\^\1,\2,/g" <<< "${line}")"
		local pgm_list=
		while read -r pgm_list
		do
			if [ -z "${pgm_list}" ]; then
				continue
			fi

			while [ $(jobs -rp | wc -l) -ge 16 ]
			do
				sleep 0.1
			done
			job &> /dev/null

			fn_generate_xml_programme_naver_thread "${channel_no}" "${pgm_list}" "${total_count}" &
		done <<< "$("${SED}" -e "/${channel_filter}/!d" "${WORKING_NAVER}")"
	done <<< "$("${SED}" -e "/^[^#].*,.*:N,/!d" "${TV_CHANNEL_CONF}")"

	wait

	echo
	echo_blue " -> " "Done."
}

fn_generate_xml_programme_naver_thread() {
	local channel="${1}"
	local pgm_list="${2}"
	local total_count="${3}"

	local pgm=
	while read -r pgm
	do
		echo -ne " -> $(fn_count_get)/${total_count}\033[0K\r"

		local begin_time="$("${SED}" -e "s/^.*\"beginDate\":\"\([^\"]*\)\",.*\"beginTime\":\"\([^\"]*\)\",.*$/\1 \2/g" <<< "${pgm}")"
		local runtime="$("${SED}" -e "s/^.*\"runtime\":\([^,]*\),.*$/\1/g" <<< "${pgm}")"

		local start="$(date -d "${begin_time}" "+%Y%m%d%H%M%S %z")"
		local end="$(date -d "${begin_time} ${runtime} minutes" "+%Y%m%d%H%M%S %z")"
	
		local title="$("${SED}" -e "s/^.*\"scheduleName\":\"\(.*\)\",\"beginDate\":.*$/\1/g" <<< "${pgm}")"
		local subtitle="$("${SED}" -e "s/^.*\"subtitle\":\"\(.*\)\",\"signLanguage\":.*$/\1/g" <<< "${pgm}")"
		local episode="$("${SED}" -e "s/^.*\"episodeNo\":\"\(.*\)\",\"live\":.*$/\1/g" <<< "${pgm}")"
		local category="$("${SED}" -e "s/^.*\"largeGenreId\":\"\([[:alnum:]]*\)\",\"episodeNo\":.*$/\1/g" <<< "${pgm}")"
		local category_en=
		case ${category} in
			A) #드라마
				category="드라마"
				category_en="Movie / Drama"
			   	;;
			B) #영화
				category="영화"
				category_en="Movie / Drama"
			   	;;
			C) #만화
				category="만화"
				category_en="Children's / Youth programmes"
				;;
			D) #연예/오락
				category="연예/오락"
				category_en="Show / Games"
				;;
			E) #스포츠
				category="스포츠"
				category_en="Sports"
				;;
			F) #취미/레저
			   	category="취미/레저"
			   	category_en="Leisure hobbies"
				;;
			G) #음악
				category="음악"
				category_en="Music / Ballet / Dance"
				;;
			H) #교육
				category="교육"
				category_en="Education / Science / Factual topics"
				;;
			I) #뉴스
				category="뉴스"
				category_en="News / Current affairs"
				;;
			J) #시사/다큐
				category="시사/다큐"
				category_en="Social / Political issues / Economics"
				;;
			K) #교양/정보
				category="교양/정보"
				category_en="Arts / Culture (without music)"
			   	;;
			L) #홍쇼핑
				category="홈쇼핑"
				category_en=""
				;;
			*) #기타
				category=""
				category_en=""
				;;
		esac

		local rating="$("${SED}" -e "s/^.*\"ageRating\":\(.*\),\"subtitle\":.*$/\1/g" <<< "${pgm}")"

		local desc="${title}"
		if [ ! -z "${subtitle}" ]; then
			desc+=" &lt;${subtitle}&gt;"
		fi
		if [ ! -z "${episode}" ]; then
			desc+=" (${episode})"
		fi
	
		local result=
		read -r -d "" result << EOF
<programme start="${start}" stop="${end}" channel="I${channel}.stonecold.kr">
	<title lang="ko">${desc}</title>
	<desc lang="ko">${desc}</desc>
	<episode-num system="onscreen">${episode}</episode-num>
	<category lang="en">${category_en}</category>
	<category lang="ko">${category}</category>
	<language>ko</language>
	<rating system="VCHIP">
		<value>${rating}</value>
	</rating>
	<generate-source name="http://tvguide.naver.com/"/>
</programme>
EOF
		fn_file_write "${OUTPUT_FILE}" "${result}"
	done <<< "$("${SED}" -e "s/^.*\"programList\":\[\(.*\)\]/\1/g" -e "s/},{/\n/g" <<< "${pgm_list}")"
}

fn_generate_xml_programme_epg() {
	if [ ! -e "${WORKING_EPG}" ]; then
		return
	fi

	local total_count="$(wc -l < "${WORKING_EPG}")"
	if [ "${total_count}" -le 0 ]; then
		return
	fi

	echo_blue " -> " "Generate Programme(epg)"

	fn_count_reset

	local line=
	while read -r line
	do
		while [ $(jobs -rp | wc -l) -ge 16 ]
		do
			sleep 0.1
		done
		job &> /dev/null

		echo -ne " -> $(fn_count_get)/${total_count}\033[0K\r"
		fn_generate_xml_programme_epg_thread "${line}" &
	done < "${WORKING_EPG}"

	wait

	echo
	echo_blue " -> " "Done."
}

fn_generate_xml_programme_epg_thread() {
	local line="${1}"

	#'channel_no','title','start','end','category'

	local channel_no="$("${SED}" -e "s/^'\(.*\)'${D}'.*'${D}'.*'${D}'.*'${D}'.*'/\1/g" <<< "${line}")"

	local title="$("${SED}" -e "s/^'.*'${D}'\(.*\)'${D}'.*'${D}'.*'${D}'.*'$/\1/g" <<< "${line}")"

	local episode="$("${SED}" -e "s/^.*(\([[:digit:]]\+회\))[[:space:]]*$/\1/g" <<< "${title}")"
	if [ "${episode}" = "${title}" ]; then
		episode=""
	else
		title="$("${SED}" -e "s/^\(.*\)[[:space:]]*([[:digit:]]\+회)[[:space:]]*/\1/g" <<< "${title}" | "${SED}" -e "s/[[:space:]]\+$//g")"
	fi

	local subtitle="$("${SED}" -e "s/^.*&lt;\(.*\)&gt;[[:space:]]*$/\1/g" <<< "${title}")"
	if [ "${subtitle}" = "${title}" ]; then
		subtitle=""
	else
		title="$("${SED}" -e "s/^\(.*\)[[:space:]]*&lt;.*&gt;[[:space:]]*$/\1/g" <<< "${title}" | "${SED}" -e "s/[[:space:]]\+$//g")"
	fi

	local desc="${title}"
	if [ ! -z "${subtitle}" ]; then
		desc+=" &lt;${subtitle}&gt;"
	fi
	if [ ! -z "${episode}" ]; then
		desc+=" (${episode})"
	fi

	local start="$("${SED}" -e "s/^'.*'${D}'.*'${D}'\(.*\)'${D}'.*'${D}'.*'/\1/g" <<< "${line}")"
	start="$(date -d "${start}" "+%Y%m%d%H%M%S %z")"

	local end="$("${SED}" -e "s/^'.*'${D}'.*'${D}'.*'${D}'\(.*\)'${D}'.*'/\1/g" <<< "${line}")"
	end="$(date -d "${end}" "+%Y%m%d%H%M%S %z")"

	local category="$("${SED}" -e "s/^'.*'${D}'.*'${D}'.*'${D}'.*'${D}'\(.*\)'/\1/g" <<< "${line}")"
	local category_en=
	case ${category//-*/} in
		드라마) #드라마
			category="드라마"
			category_en="Movie / Drama"
			;;
		영화) #영화
			category="영화"
			category_en="Movie / Drama"
			;;
		만화) #만화
			category="만화"
			category_en="Children's / Youth programmes"
			;;
		연예/오락) #연예/오락
			category="연예/오락"
			category_en="Show / Games"
			;;
		스포츠) #스포츠
			category="스포츠"
			category_en="Sports"
			;;
		취미/레저) #취미/레저
			category="취미/레저"
			category_en="Leisure hobbies"
			;;
		음악) #음악
			category="음악"
			category_en="Music / Ballet / Dance"
			;;
		교육) #교육
			category="교육"
			category_en="Education / Science / Factual topics"
			;;
		뉴스) #뉴스
			category="뉴스"
			category_en="News / Current affairs"
			;;
		시사/다큐) #시사/다큐
			category="시사/다큐"
			category_en="Social / Political issues / Economics"
			;;
		교양/정보) #교양/정보
			category="교양/정보"
			category_en="Arts / Culture (without music)"
			;;
		홈쇼핑) #홍쇼핑
			category="홈쇼핑"
			category_en=""
			;;
		*) #기타
			category=""
			category_en=""
			;;
	esac

	local result=
	read -r -d "" result << EOF
<programme start="${start}" stop="${end}" channel="I${channel_no}.stonecold.kr">
	<title lang="ko">${desc}</title>
	<desc lang="ko">${desc}</desc>
	<episode-num system="onscreen">${episode}</episode-num>
	<category lang="en">${category_en}</category>
	<category lang="ko">${category}</category>
	<language>ko</language>
	<generate-source name="http://www.epg.co.kr/"/>
</programme>
EOF
	fn_file_write "${OUTPUT_FILE}" "${result}"
}

fn_generate_xml_programme() {
	if [ -e "${WORKING_UPLUS}" ]; then
		fn_generate_xml_programme_uplus
	fi

	if [ -e "${WORKING_NAVER}" ]; then
		fn_generate_xml_programme_naver
	fi

	if [ -e "${WORKING_EPG}" ]; then
		fn_generate_xml_programme_epg
	fi
}

fn_generate_footer() {
	echo_blue " -> " "Generate Footer"
	local result=
	read -r -d "" result << EOF
</tv>
EOF
	fn_file_write "${OUTPUT_FILE}" "${result}"
	echo_blue " -> " "Done."
}

fn_generate_xml() {
	echo_green "==> " "Generate XML"

	fn_generate_xml_header

	fn_generate_xml_channel

	fn_generate_xml_programme

	fn_generate_footer

	echo_green "==> " "Done."
	echo
}

fn_cleanup() {
	echo_green "==> " "Cleanup"

	wait

	"${SED}" -i -e "s/>[[:space:]]\+<\//><\//g" -e "/<episode-num system=\"onscreen\"><\/episode-num>/d" -e "/[[:space:]]*<rating system=\"VCHIP\">.*/ {N;N; /[[:space:]]*<rating system=\"VCHIP\">.*<value>0\?<\/value>.*<\/rating>/d}" "${OUTPUT_FILE}"

	if [ "${XMLTV_FILE//\.gz/}" != "${XMLTV_FILE}" ]; then
		gzip -9 "${OUTPUT_FILE}"
		mv "${OUTPUT_FILE}.gz" "${XMLTV_FILE}"
	else
		mv "${OUTPUT_FILE}" "${XMLTV_FILE}"
	fi
	if [ "${DEBUG}" = "0" ]; then
		rm -rf "${WORKING_DIR}"
	fi

	date +"%F %T" >> "${TIMESTAMP}"

	echo_green "==> " "Done."
	echo
}

fn_postproc() {
	if [ -e "${XMLTV_FILE}" -a -x ./postproc.sh ]; then
		echo_green "==> " "Start Postproc"

		./postproc.sh "${XMLTV_FILE}"

		echo_green "==> " "Done."
		echo
	fi
}

#Validation
fn_validation

#Preproc
fn_preproc

#Download
fn_download

#Generate XML
fn_generate_xml

#Cleanup
fn_cleanup

#Postproc
fn_postproc

exit

