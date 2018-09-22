decl str ycmd_path
decl int ycmd_port 12345

decl -hidden int ycmd_pid 0
decl -hidden str ycmd_hmac_key
decl -hidden str ycmd_tmp_dir
decl -hidden completions ycmd_completions

def ycmd-start %{ evaluate-commands %sh{
    if [ -z "${kak_opt_ycmd_path}" ]; then
        echo "echo -color Error 'ycmd_path option must be set to the ycmd/ycmd dir'"
    fi

    dir=$(mktemp -d -t kak-ycmd.XXXXXXXX)
    # Avoid null bytes in the key, as we need to pass it as an argument to openssl
    key=$(dd if=/dev/urandom bs=16 count=1 status=none | tr '\0' '@' | base64 -w0)
    mkfifo ${dir}/fifo

    cat > ${dir}/options.json <<EOF
{
  "filepath_completion_use_working_dir": 0,
  "auto_trigger": 1,
  "min_num_of_chars_for_completion": 2,
  "min_num_identifier_candidate_chars": 0,
  "semantic_triggers": {},
  "filetype_specific_completion_to_disable": { "gitcommit": 1 },
  "seed_identifiers_with_syntax": 0,
  "collect_identifiers_from_comments_and_strings": 0,
  "collect_identifiers_from_tags_files": 0,
  "extra_conf_globlist": [],
  "global_ycm_extra_conf": "",
  "confirm_extra_conf": 0,
  "complete_in_comments": 0,
  "complete_in_strings": 1,
  "max_diagnostics_to_display": 30,
  "filetype_whitelist": { "*": 1 },
  "filetype_blacklist": { },
  "auto_start_csharp_server": 1,
  "auto_stop_csharp_server": 1,
  "use_ultisnips_completer": 1,
  "csharp_server_port": 2000,
  "hmac_secret": "$key",
  "server_keep_logfiles": 0
}
EOF
    echo "set global ycmd_tmp_dir ${dir}
          set global ycmd_hmac_key ${key}
          hook global KakEnd .* %{ ycmd-stop }
          eval -draft %{
              edit! -fifo ${dir}/fifo *ycmd-output*
              hook buffer BufCloseFifo .* %{ nop %sh{ rm -r ${dir} } }
          }"

    (
        python3 ${kak_opt_ycmd_path} --port ${kak_opt_ycmd_port} --options_file ${dir}/options.json --log debug > ${dir}/fifo 2>&1 &
        echo "set global ycmd_pid $!" | kak -p ${kak_session}
    ) > /dev/null 2>&1 < /dev/null &
} }

def ycmd-stop %{
    nop %sh{ if [ ${kak_opt_ycmd_pid} -gt 0 ]; then kill ${kak_opt_ycmd_pid}; fi }
    set global ycmd_pid 0
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
                \"force_semantic\": true,
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
            compl=$(printf '%s' "$json" | jq -j '.completions[] | "\(.insertion_text)|\(.menu_text)|\(.insertion_text)" | gsub(":"; "\\:") + ":"' 2> ${dir}/jq-err | head -c -1)
            column=$(printf '%s' "$json" | jq -j .completion_start_column 2>> ${dir}/jq-err)
            header="${kak_cursor_line}.${column}@${kak_timestamp}"
            compl="${header}:${compl}"
            compl="${compl//(/[}"
            compl="${compl//)/]}"
            echo "eval -client ${kak_client} %(echo completed; set 'buffer=${kak_buffile}' ycmd_completions %(${compl}) )" | kak -p ${kak_session}
        ) > /dev/null 2>&1 < /dev/null &
    }
}

def ycmd-enable-autocomplete %{
    set buffer ycmd_completions %opt{ycmd_completions}
    set -add buffer completers option=ycmd_completions
    hook -group ycmd_autocomplete window InsertIdle .* %{ try %{
        exec -draft <a-h><a-k>(\.|->|::).<ret>
        echo 'completing...'
        ycmd-complete
    } }
}

def ycmd-disable-autocomplete %{
    rmhooks window ycmd_autocomplete
    unset-option buffer ycmd_completions
}
