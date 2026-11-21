#!/bin/zsh

# Never trace commands while handling a credential, even if tracing was inherited.
set +x
set -euo pipefail

watch_device_id="${WATCH_DEVICE_ID:-}"
watch_bundle_id="${WATCH_BUNDLE_ID:-com.example.wristassistant.watchkitapp}"
xcode_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
deepseek_keychain_service="${DEEPSEEK_KEYCHAIN_SERVICE:-com.example.wristassistant.deepseek}"
deepseek_keychain_account="${DEEPSEEK_KEYCHAIN_ACCOUNT:-api-key}"
setup_temp_dir=""
deepseek_api_key=""
read_existing_keychain="false"
verify_ai="false"

for setup_option in "$@"; do
    case "$setup_option" in
        --from-keychain) read_existing_keychain="true" ;;
        --verify-ai) verify_ai="true" ;;
        --help)
            printf '默认：本机隐藏输入，仅保存到新手表 Keychain，检查鉴权，不运行问答。\n'
            printf '可选：--from-keychain 读取已有的指定 macOS 钥匙串项。\n'
            printf '可选：--verify-ai 显式运行会消耗 API 额度的问答验收。\n'
            exit 0 ;;
        *) printf '未知选项。请使用 --help 查看用法。\n'; exit 2 ;;
    esac
done

if [[ -z "$watch_device_id" ]]; then
    printf '请设置 WATCH_DEVICE_ID 为 xcrun devicectl list devices 显示的目标手表标识符。\n' >&2
    exit 2
fi

# An unrelated parent-shell probe must never cause paid requests implicitly.
unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID 2>/dev/null || true
unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND 2>/dev/null || true

cleanup() {
    unset DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_KEY 2>/dev/null || true
    unset DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_ATTEMPT_ID 2>/dev/null || true
    unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID 2>/dev/null || true
    unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND 2>/dev/null || true
    deepseek_api_key=""
    if [[ -n "${setup_temp_dir:-}" && -d "$setup_temp_dir" ]]; then
        rm -rf -- "$setup_temp_dir"
    fi
}
trap cleanup EXIT INT TERM

setup_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/wrist-deepseek-setup.XXXXXX")"
import_receipt_file="$setup_temp_dir/deepseek-import-ack.json"
acceptance_receipt_file="$setup_temp_dir/acceptance-probe-ack.json"
setup_attempt_id="$(uuidgen)"

pause_before_exit() {
    if [[ -t 0 ]]; then
        read -r '?按回车关闭…'
    fi
}

copy_receipt() {
    local source_name="$1"
    local destination_path="$2"
    rm -f -- "$destination_path"
    DEVELOPER_DIR="$xcode_developer_dir" xcrun devicectl device copy from \
        --device "$watch_device_id" \
        --domain-type appDataContainer \
        --domain-identifier "$watch_bundle_id" \
        --source "Library/Caches/$source_name" \
        --destination "$destination_path" \
        --timeout 15 >/dev/null 2>&1
}

printf '请先解锁 Apple Watch，并保持屏幕亮着。\n'
printf '目标：所选 Apple Watch 上的“腕上助手”。\n'
printf '密钥仅用于 DeepSeek 官方鉴权及写入手表 Keychain，不写入源码、日志或 Mac 钥匙串。\n'
if [[ "$verify_ai" == "true" ]]; then
    printf '已显式选择问答验收：保存后会消耗少量 DeepSeek API 额度。\n'
else
    printf '本次仅配置并检查鉴权，不运行问答或模型验收。\n'
fi

if [[ "$read_existing_keychain" == "true" ]]; then
    deepseek_api_key="$(
        security find-generic-password \
            -a "$deepseek_keychain_account" \
            -s "$deepseek_keychain_service" \
            -w 2>/dev/null || true
    )"
    if [[ -z "$deepseek_api_key" ]]; then
        printf '没有找到指定钥匙串项，请不带 --from-keychain 重新运行并隐藏输入。\n'
        pause_before_exit
        exit 1
    fi
    printf '已从指定 macOS 钥匙串项读取密钥，不会显示。\n'
elif [[ -t 0 ]]; then
    printf '请输入 DeepSeek API Key（输入不会显示）：\n'
    IFS= read -r -s deepseek_api_key
    printf '\n'
else
    printf '当前终端无法进行隐藏输入；请在本机终端窗口运行此文件。\n'
    exit 1
fi

if (( ${#deepseek_api_key} < 8 || ${#deepseek_api_key} > 512 )) \
    || [[ "$deepseek_api_key" == *[[:space:]]* ]]; then
    deepseek_api_key=""
    printf 'API Key 格式不正确，未发送任何内容。\n'
    pause_before_exit
    exit 1
fi

printf '正在向 DeepSeek 官方验证 API Key（不会显示 Key，也不会产生模型 token 用量）…\n'
deepseek_status="$(
    printf 'Authorization: Bearer %s\n' "$deepseek_api_key" \
        | /usr/bin/curl \
            --silent \
            --show-error \
            --output /dev/null \
            --write-out '%{http_code}' \
            --connect-timeout 10 \
            --max-time 20 \
            --header @- \
            https://api.deepseek.com/models \
            2>/dev/null || true
)"
if [[ "$deepseek_status" != "200" ]]; then
    deepseek_api_key=""
    if [[ "$deepseek_status" == "401" || "$deepseek_status" == "403" ]]; then
        printf 'DeepSeek 拒绝了这个 API Key；未保存也未发送到手表。\n'
    else
        printf '暂时无法完成 DeepSeek Key 验证（HTTP %s）；未保存也未发送。\n' \
            "${deepseek_status:-网络错误}"
    fi
    pause_before_exit
    exit 1
fi

export DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_KEY="$deepseek_api_key"
export DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_ATTEMPT_ID="$setup_attempt_id"
if [[ "$verify_ai" == "true" ]]; then
    export DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID="$setup_attempt_id"
    export DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND="ai"
fi

if ! DEVELOPER_DIR="$xcode_developer_dir" xcrun devicectl device process launch \
    --device "$watch_device_id" \
    --terminate-existing \
    --timeout 30 \
    "$watch_bundle_id" >/dev/null 2>&1; then
    printf '\n发送失败。请确认手表已解锁、靠近 Mac，然后重新运行此文件。\n'
    pause_before_exit
    exit 1
fi

unset DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_KEY
unset DEVICECTL_CHILD_WRIST_DEEPSEEK_SETUP_ATTEMPT_ID
unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_ID
unset DEVICECTL_CHILD_WRIST_ACCEPTANCE_PROBE_KIND
deepseek_api_key=""

imported="false"
for _ in {1..12}; do
    if copy_receipt "deepseek-import-ack.json" "$import_receipt_file"; then
        receipt_attempt_id="$(
            plutil -extract attempt_id raw -o - "$import_receipt_file" 2>/dev/null || true
        )"
        receipt_success="$(
            plutil -extract succeeded raw -o - "$import_receipt_file" 2>/dev/null || true
        )"
        if [[ "$receipt_attempt_id" == "$setup_attempt_id" \
            && "$receipt_success" == "true" ]]; then
            imported="true"
            break
        fi
    fi
    sleep 1
done

if [[ "$imported" != "true" ]]; then
    receipt_message="$(
        plutil -extract message raw -o - "$import_receipt_file" 2>/dev/null || true
    )"
    printf '\n未收到本次 DeepSeek Key 配置的成功回执。\n'
    [[ -n "$receipt_message" ]] && printf '%s\n' "$receipt_message"
    pause_before_exit
    exit 1
fi

printf '\n已核验：DeepSeek API Key 已写入真表 Keychain。\n'
if [[ "$verify_ai" != "true" ]]; then
    printf '完成：仅配置密钥，未运行问答验收。现在可在手表上打开“新对话”。\n'
    pause_before_exit
    exit 0
fi
printf '正在等待真表完成多轮、联网搜索、深度思考与流式回答验收…\n'

accepted="false"
acceptance_source="acceptance-probe-ack-$setup_attempt_id.json"
for _ in {1..45}; do
    if copy_receipt "$acceptance_source" "$acceptance_receipt_file"; then
        receipt_attempt_id="$(
            plutil -extract attempt_id raw -o - "$acceptance_receipt_file" 2>/dev/null || true
        )"
        receipt_success="$(
            plutil -extract succeeded raw -o - "$acceptance_receipt_file" 2>/dev/null || true
        )"
        if [[ "$receipt_attempt_id" == "$setup_attempt_id" ]]; then
            [[ "$receipt_success" == "true" ]] && accepted="true"
            break
        fi
    fi
    sleep 2
done

acceptance_message="$(
    plutil -extract message raw -o - "$acceptance_receipt_file" 2>/dev/null || true
)"
acceptance_code="$(
    plutil -extract code raw -o - "$acceptance_receipt_file" 2>/dev/null || true
)"

if [[ "$accepted" == "true" ]]; then
    printf '真表 DeepSeek 验收通过：%s\n' "$acceptance_code"
    [[ -n "$acceptance_message" ]] && printf '%s\n' "$acceptance_message"
else
    printf 'Key 已保存，但本次真表 DeepSeek 网络验收未通过。\n'
    [[ -n "$acceptance_code" ]] && printf '结果码：%s\n' "$acceptance_code"
    [[ -n "$acceptance_message" ]] && printf '%s\n' "$acceptance_message"
    pause_before_exit
    exit 1
fi

pause_before_exit
