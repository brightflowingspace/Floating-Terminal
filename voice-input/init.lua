-- ============================================================
-- 音声入力 (右Commandキー単体を押している間だけ録音 → whisper.cppでローカル文字起こし → 入力欄に自動入力)
-- 修飾キー単体なのでIMEに文字として解釈されず、余計な空白が入る心配がない
-- 押している間も、約1秒ごとにそこまでを文字にして画面の下に出す(2026-10-17)
-- ============================================================

hs.autoLaunch(true) -- Mac起動時にHammerspoonを自動起動
require("hs.ipc")

local HOME = os.getenv("HOME")
local REC_BIN = "/opt/homebrew/bin/rec"
local WHISPER_BIN = "/opt/homebrew/bin/whisper-cli"
local WHISPER_MODEL = HOME .. "/.whisper-models/ggml-base.bin"
-- 録音はヘッダのない生データ(16kHz・モノラル・16bit)で書き、文字にするたびにWAVに包む
-- (録音中のWAVはヘッダの長さが未確定で、途中で読めないため)
local RAW_PATH = "/tmp/hs_voice_input.raw"
local WAV_PATH = "/tmp/hs_voice_input.wav"
local OUT_BASE = "/tmp/hs_voice_input_out"
local PREVIEW_WAV = "/tmp/hs_voice_preview.wav"
local PREVIEW_OUT = "/tmp/hs_voice_preview_out"
local PREVIEW_INTERVAL = 1.0 -- 途中の文字を出す間隔(秒)

local recording = false
local recTask = nil
local previewTimer = nil
local previewTask = nil
local menu = hs.menubar.new()
menu:setTitle("🎤")

-- whisperの出力先頭/末尾によく付く全角スペース・半角空白をまとめて除去
local IDEOGRAPHIC_SPACE = "\227\128\128" -- U+3000 の UTF-8バイト列
local function trimVoiceText(s)
    while true do
        if s:sub(1, 1):match("%s") then
            s = s:sub(2)
        elseif s:sub(1, 3) == IDEOGRAPHIC_SPACE then
            s = s:sub(4)
        else
            break
        end
    end
    while true do
        if s:sub(-1):match("%s") then
            s = s:sub(1, -2)
        elseif s:sub(-3) == IDEOGRAPHIC_SPACE then
            s = s:sub(1, -4)
        else
            break
        end
    end
    return s
end

-- whisperが無音のところで勝手に書く決まり文句(動画の締めの言葉など)を消す
local HALLUCINATIONS = {
    "ご視聴ありがとうございました",
    "ご清聴ありがとうございました",
    "チャンネル登録よろしくお願いします",
    "最後までご視聴いただきありがとうございます",
}
local function removeHallucinations(s)
    for _, h in ipairs(HALLUCINATIONS) do
        local start, finish = s:find(h, 1, true)
        while start do
            local rest = s:sub(finish + 1)
            -- 後ろに続く句点・感嘆符もいっしょに消す
            for _, p in ipairs({ "。", "．", "！", ".", "!" }) do
                if rest:sub(1, #p) == p then rest = rest:sub(#p + 1); break end
            end
            s = s:sub(1, start - 1) .. rest
            start, finish = s:find(h, 1, true)
        end
    end
    return s
end

local function cleanText(s)
    return trimVoiceText(removeHallucinations(trimVoiceText(s)))
end

-- ── 押している間の文字を出す窓(画面の下の真ん中) ──
local overlay = nil
local function showOverlay(text)
    if not overlay then
        local frame = hs.screen.mainScreen():frame()
        local w = math.min(900, frame.w - 80)
        local h = 120
        overlay = hs.canvas.new({ x = frame.x + (frame.w - w) / 2, y = frame.y + frame.h - h - 60, w = w, h = h })
        overlay:level(hs.canvas.windowLevels.overlay)
        overlay:behavior({ "canJoinAllSpaces", "stationary" })
        overlay[1] = { type = "rectangle", action = "fill", fillColor = { white = 0.1, alpha = 0.88 },
                       roundedRectRadii = { xRadius = 14, yRadius = 14 } }
        overlay[2] = { type = "text", text = "", textSize = 18, textColor = { white = 1 },
                       frame = { x = 20, y = 14, w = w - 40, h = h - 28 } }
    end
    overlay[2].text = text
    overlay:show()
end

local function hideOverlay()
    if overlay then
        overlay:delete()
        overlay = nil
    end
end

-- 生データにWAVのヘッダ(44バイト)を付けて書き出す
local function writeWavFromRaw(rawPath, wavPath)
    local f = io.open(rawPath, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    if not data or #data < 3200 then return false end -- 0.1秒未満は読まない
    if #data % 2 == 1 then data = data:sub(1, -2) end -- 書きかけの半端な1バイトは捨てる
    local function u32(n) return string.char(n % 256, (n >> 8) % 256, (n >> 16) % 256, (n >> 24) % 256) end
    local function u16(n) return string.char(n % 256, (n >> 8) % 256) end
    local rate, ch, bits = 16000, 1, 16
    local header = "RIFF" .. u32(36 + #data) .. "WAVE" .. "fmt " .. u32(16) .. u16(1) .. u16(ch)
        .. u32(rate) .. u32(rate * ch * bits // 8) .. u16(ch * bits // 8) .. u16(bits)
        .. "data" .. u32(#data)
    local out = io.open(wavPath, "wb")
    if not out then return false end
    out:write(header, data)
    out:close()
    return true
end

local function whisperArgs(wav, outBase)
    return {
        "-m", WHISPER_MODEL,
        "-f", wav,
        "-l", "ja",
        "-otxt", "-of", outBase,
        "-nt", "-np",
        "--suppress-nst",
    }
end

local function readText(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

-- 押している間、そこまでの録音を文字にして窓に出す(前の分が終わっていなければ次の回まで待つ)
local function runPreview()
    if not recording or previewTask then return end
    if not writeWavFromRaw(RAW_PATH, PREVIEW_WAV) then return end
    os.remove(PREVIEW_OUT .. ".txt")
    previewTask = hs.task.new(WHISPER_BIN, function()
        previewTask = nil
        if not recording then return end
        local text = readText(PREVIEW_OUT .. ".txt")
        if text then
            text = cleanText(text)
            if text ~= "" then showOverlay("🎤 " .. text) end
        end
    end, whisperArgs(PREVIEW_WAV, PREVIEW_OUT))
    previewTask:start()
end

local function stopRecProcess()
    if recTask then
        local pid = recTask:pid()
        if pid then
            hs.execute("kill -INT " .. pid)
        end
        recTask = nil
    end
end

local function startRecording()
    recording = true
    os.remove(RAW_PATH)
    menu:setTitle("🔴")
    hs.alert.closeAll()
    showOverlay("🎤 録音中... (キーを離すと入力)")

    recTask = hs.task.new(REC_BIN, nil, function() return true end,
        {"-q", "-r", "16000", "-c", "1", "-b", "16", "-e", "signed-integer", "-t", "raw", RAW_PATH})
    recTask:start()
    previewTimer = hs.timer.doEvery(PREVIEW_INTERVAL, runPreview)
end

local function stopRecordingAndTranscribe()
    recording = false
    if previewTimer then previewTimer:stop(); previewTimer = nil end
    if previewTask then previewTask:terminate(); previewTask = nil end
    stopRecProcess()
    menu:setTitle("⏳")
    showOverlay("⏳ 文字起こし中...")

    -- soxがファイルを閉じるまで少し待つ
    hs.timer.doAfter(0.4, function()
        os.remove(OUT_BASE .. ".txt")
        if not writeWavFromRaw(RAW_PATH, WAV_PATH) then
            hideOverlay()
            menu:setTitle("🎤")
            hs.alert.show("(短すぎて認識できませんでした)")
            return
        end
        local task = hs.task.new(WHISPER_BIN, function()
            hideOverlay()
            menu:setTitle("🎤")

            local text = readText(OUT_BASE .. ".txt")
            if not text then
                hs.alert.show("⚠️ 文字起こしに失敗しました")
                return
            end
            text = cleanText(text)

            if text == "" then
                hs.alert.show("(認識できませんでした)")
            else
                hs.eventtap.keyStrokes(text)
            end
        end, whisperArgs(WAV_PATH, OUT_BASE))
        task:start()
    end)
end

-- 右Commandキー単体の押しっぱなしで録音（Push-to-talk）
-- 修飾キーはflagsChangedイベントとして扱われ、文字入力とは無関係なので安全
-- ※ local にすると、しばらくして片付けられ(GC)反応しなくなるので、グローバルに持つ
local RIGHT_CMD_KEYCODE = 54

modWatcher = hs.eventtap.new({
    hs.eventtap.event.types.flagsChanged,
}, function(event)
    if event:getKeyCode() ~= RIGHT_CMD_KEYCODE then
        return false
    end

    local isDown = event:getFlags().cmd

    if isDown then
        if not recording then
            startRecording()
        end
    else
        if recording then
            stopRecordingAndTranscribe()
        end
    end
    return false
end)
modWatcher:start()

hs.alert.show("音声入力の準備ができました (右Commandキーを押しながら話す)")
