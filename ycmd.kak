decl str kak_ycmd_path %sh{ echo "$HOME/.local/share/kak-ycmd" }
decl str ycmd_settings_template_path %sh{ echo "${kak_opt_kak_ycmd_path}/default_settings.json.template" }
decl int ycmd_port 12345

decl -hidden int ycmd_pid 0
decl -hidden str ycmd_hmac_key
decl -hidden str ycmd_tmp_dir
decl -hidden completions ycmd_completions


def ycmd-start %{ evaluate-commands %sh{
    dir=$(mktemp -d -t kak-ycmd.XXXXXXXX)
    # Avoid null bytes in the key, as we need to pass it as an argument to openssl
    key=$(dd if=/dev/urandom bs=16 count=1 status=none | tr '\0' '@' | base64 -w0)
    mkfifo ${dir}/fifo

    cp "${kak_opt_ycmd_settings_template_path}" ${dir}/options.json
    sed -i -e "s*__HMAC_SECRET__*${key}*g" ${dir}/options.json

    echo "set global ycmd_tmp_dir ${dir}
          set global ycmd_hmac_key ${key}
          hook global KakEnd .* %{ ycmd-stop }
          eval -draft %{
              edit! -fifo ${dir}/fifo *ycmd-output*
              hook buffer BufCloseFifo .* %{ nop %sh{ rm -r ${dir} } }
          }"

    (
        python3 ${kak_opt_kak_ycmd_path}/ycmd/ycmd --port ${kak_opt_ycmd_port} --options_file ${dir}/options.json --idle_suicide_seconds=7200 --log debug > ${dir}/fifo 2>&1 &
        echo "set global ycmd_pid $!" | kak -p ${kak_session}
    ) > /dev/null 2>&1 < /dev/null &
} }

def ycmd-stop %{
    nop %sh{ if [ ${kak_opt_ycmd_pid} -gt 0 ]; then kill ${kak_opt_ycmd_pid}; fi }
    set global ycmd_pid 0
}

def mk %{
    make
    ycmd-stop
    ycmd-start
}

def ycmd-complete %{
    evaluate-commands %sh{
        if [ ${kak_opt_ycmd_pid} -eq 0 ]; then
            echo "echo 'auto starting ycmd server'
                  ycmd-start"
        fi
    }
    evaluate-commands %sh{ echo "write ${kak_opt_ycmd_tmp_dir}/buf.cpp" }
    # end the previous %sh{} so that its output gets interpreted by kakoune
    # before launching the following as a background task.
    evaluate-commands %sh{
        dir=${kak_opt_ycmd_tmp_dir}
        # this runs in a detached shell, asynchronously, so that kakoune does not hang while ycmd is running.
        # As completions references a cursor position and a buffer timestamp, only valid completions should be
        # displayed.
        (
            key=$(printf '%s' "${kak_opt_ycmd_hmac_key}" | base64 -d -w0)

            compute_hmac() { openssl dgst -sha256 -hmac "$key" -binary; }

            query="{
                \"line_num\": $kak_cursor_line,
                \"column_num\": $kak_cursor_column,
                \"filepath\": \"$kak_buffile\",
                \"file_data\": {
                    \"$kak_buffile\": {
                        \"filetypes\": [ \"$kak_opt_filetype\" ],
                        \"contents\": $(jq -Rs . $dir/buf.cpp)
                    }
                }
            }"
            port=${kak_opt_ycmd_port}
            path="/completions"
            method="POST"

            path_hmac=$(printf '%s' "$path" | compute_hmac | base64 -w0)
            method_hmac=$(printf '%s' "$method" | compute_hmac | base64 -w0)
            body_hmac=$(printf '%s' "$query" | compute_hmac | base64 -w0)
            hmac=$(printf '%s' "${method_hmac}${path_hmac}${body_hmac}" | base64 -d -w0 | compute_hmac | base64 -w0)

httphdr="Content-Type: application/json; charset=utf8
X-Ycm-Hmac: $hmac"

            json=$(curl -H "$httphdr" "http://127.0.0.1:${port}${path}" -d "$query" 2> ${dir}/curl-err)
            compl=$(printf '%s' "$json" | jq -j ".completions[] | \"'\"+.insertion_text+\"|\"+.extra_menu_info+\"|\"+.menu_text+\"' \"" 2> ${dir}/jq-err | head -c -1)
            column=$(printf '%s' "$json" | jq -j .completion_start_column 2>> ${dir}/jq-err)
            header="'${kak_cursor_line}.${column}@${kak_timestamp}'"
            compl="${header} ${compl}"
            printf '%s' "eval -client ${kak_client} %{echo completed; set 'buffer=${kak_buffile}' ycmd_completions ${compl}}" | kak -p ${kak_session}
        ) > /dev/null 2>&1 < /dev/null &
    }
}

def ycmd-enable-autocomplete %{
    set buffer ycmd_completions %opt{ycmd_completions}
    set -add buffer completers option=ycmd_completions
    hook -group ycmd_autocomplete window InsertIdle .* %{ try %{
        echo 'completing...'
        ycmd-complete
    } }
}

def ycmd-disable-autocomplete %{
    rmhooks window ycmd_autocomplete
    unset-option buffer ycmd_completions
}

# For debugging: send a request with path $1 and print the response to the debug window
def -params 1 ycmd-request %{
    evaluate-commands %sh{
        if [ ${kak_opt_ycmd_pid} -eq 0 ]; then
            echo "echo 'auto starting ycmd server'
                  ycmd-start"
        fi
    }
    evaluate-commands %sh{ echo "write ${kak_opt_ycmd_tmp_dir}/buf.cpp" }
    # end the previous %sh{} so that its output gets interpreted by kakoune
    # before launching the following as a background task.
    evaluate-commands %sh{
        dir=${kak_opt_ycmd_tmp_dir}
        # this runs in a detached shell, asynchronously, so that kakoune does not hang while ycmd is running.
        # As completions references a cursor position and a buffer timestamp, only valid completions should be
        # displayed.
        (
            key=$(printf '%s' "${kak_opt_ycmd_hmac_key}" | base64 -d -w0)

            compute_hmac() { openssl dgst -sha256 -hmac "$key" -binary; }

            query="{
                \"line_num\": $kak_cursor_line,
                \"column_num\": $kak_cursor_column,
                \"filepath\": \"$kak_buffile\",
                \"file_data\": {
                    \"$kak_buffile\": {
                        \"filetypes\": [ \"$kak_opt_filetype\" ],
                        \"contents\": $(jq -Rs . $dir/buf.cpp)
                    }
                }
            }"
            port=${kak_opt_ycmd_port}
            path="/${1}"
            method="POST"

            path_hmac=$(printf '%s' "$path" | compute_hmac | base64 -w0)
            method_hmac=$(printf '%s' "$method" | compute_hmac | base64 -w0)
            body_hmac=$(printf '%s' "$query" | compute_hmac | base64 -w0)
            hmac=$(printf '%s' "${method_hmac}${path_hmac}${body_hmac}" | base64 -d -w0 | compute_hmac | base64 -w0)

httphdr="Content-Type: application/json; charset=utf8
X-Ycm-Hmac: $hmac"

            json=$(curl -H "$httphdr" "http://127.0.0.1:${port}${path}" -d "$query" 2> ${dir}/curl-err)
            printf '%s' "$json" | jq . > ${dir}/fifo
        ) > /dev/null 2>&1 < /dev/null &
    }
}
