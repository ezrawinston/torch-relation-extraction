--
-- User: pat
-- Date: 9/17/15
--


require 'torch'
require 'rnn'
require '../nn-modules/ViewTable.lua'
require '../nn-modules/ReplicateAs.lua'
require '../nn-modules/SelectLast.lua'
require '../nn-modules/VariableLengthJoinTable.lua'
require '../nn-modules/VariableLengthConcatTable.lua'
require '../nn-modules/NoUpdateLookupTable.lua'
require '../nn-modules/NoUnReverseBiSequencer.lua'
require '../nn-modules/WordDropout.lua'

--[[
    Takes a tac candidate file, tab seperated vocab idx file, and a trained uschema encoder model
    and exports a scored candidtate file to outfile
]]--
local cmd = torch.CmdLine()
cmd:option('-candidates', '', 'input candidate file')
cmd:option('-outFile', '', 'scored candidate out file')
cmd:option('-vocabFile', '', 'txt file containing vocab-index map')
cmd:option('-dictionary', '', 'txt file containing en-es dictionary')
cmd:option('-maxSeq', 999999, 'throw away sequences longer than this')
cmd:option('-model', '', 'a trained model that will be used to score candidates')
cmd:option('-delim', ' ', 'delimiter to split lines on')
cmd:option('-threshold', .001, 'scores below this threshold will be set to -1e100')
cmd:option('-gpuid', -1, 'Which gpu to use, -1 for cpu (default)')
cmd:option('-relations', false, 'Use full relation vectors instead of tokens')
cmd:option('-logRelations', false, 'Use log relation vectors instead of tokens')
cmd:option('-doubleVocab', false, 'double vocab so that tokens to the right of ARG1 are different then to the right of ARG2')
cmd:option('-appendEs', false, 'append @es to end of relation')
cmd:option('-normalizeDigits', false, 'map all digits to #')
cmd:option('-tokenAppend', '', 'append this to the end of each token')
cmd:option('-fullPath', false, 'use the full input pattern without any segmenting')


local params = cmd:parse(arg)
local function to_cuda(x) return params.gpuid >= 0 and x:cuda() or x end
if params.gpuid >= 0 then require 'cunn'; cutorch.manualSeed(0); cutorch.setDevice(params.gpuid + 1) else require 'nn' end

local in_vocab = 0
local out_vocab = 0


--- convert sentence to tac tensor using tokens ---
local function token_tensor(arg1_first, pattern_rel, vocab_map, dictionary, start_idx, end_idx, use_full_pattern)
    local idx = 0
    local i = 0
    local token_ids = {}
    local tokens = {}

    local first_arg, second_arg
    if arg1_first then first_arg = '$ARG1'; second_arg = '$ARG2' else first_arg = '$ARG2'; second_arg = '$ARG2' end
    if params.tokenAppend ~= '' then first_arg = first_arg .. params.tokenAppend second_arg = second_arg .. params.tokenAppend end

    for token in string.gmatch(pattern_rel, "[^" .. params.delim .. "]+") do
        if dictionary[token] then token = dictionary[token]
        elseif params.tokenAppend ~= '' then token = token .. params.tokenAppend
        end
        if (idx >= start_idx and idx < end_idx) or use_full_pattern then table.insert(tokens, token) end
        idx = idx + 1
    end

    if not use_full_pattern then table.insert(token_ids, vocab_map[first_arg] or 1) end
    for i = 1, #tokens do
        local token
        if not params.logRelations or #tokens <= 4 or i <= 2 or i > #tokens -2 then
            token = tokens[i]
        elseif i == 3 then
            token = '[' .. math.floor(torch.log(#tokens - 4)/torch.log(2)) .. ']'
        end
        if token then
            if params.doubleVocab then token = token .. '_' .. (arg1_first and '$ARG1' or '$ARG2') end
            local id = vocab_map[token] or 1
            table.insert(token_ids, id)
            if id == 1 then out_vocab = out_vocab + 1 else in_vocab = in_vocab + 1 end
        end
    end

    if not use_full_pattern then table.insert(token_ids, vocab_map[second_arg] or 1) end
    local pattern_tensor = torch.Tensor(token_ids)
    return pattern_tensor, #tokens
end

--- convert sentence to tac tensor using whole relation tensor ---
local function rel_tensor(arg1_first, pattern_rel, vocab_map, start_idx, end_idx, use_full_pattern)
    local rel_string
    if not use_full_pattern then
        local idx = 0
        local tokens = {}
        for token in string.gmatch(pattern_rel, "[^" .. params.delim .. "]+") do
            if params.tokenAppend ~= '' then token = token .. params.tokenAppend end
            if idx >= start_idx and idx < end_idx then table.insert(tokens, token) end
            idx = idx + 1
        end

        local first_arg = arg1_first and '$ARG1' or '$ARG2'
        if params.tokenAppend ~= '' then first_arg = first_arg .. params.tokenAppend end
        rel_string = first_arg .. ' '
        for i = 1, #tokens do
            if not params.logRelations or #tokens <= 4 or i <= 2 or i > #tokens - 2 then
                rel_string = rel_string .. tokens[i] .. ' '
            elseif i == 3 then
                rel_string = rel_string .. '[' .. math.floor(torch.log(#tokens - 4) / torch.log(2)) .. ']' .. ' '
            end
        end
        local second_arg = arg1_first and '$ARG2' or '$ARG1'
        if params.tokenAppend ~= '' then second_arg = second_arg .. params.tokenAppend end
        rel_string = rel_string .. second_arg
    else
        rel_string = pattern_rel
    end
    if params.appendEs then rel_string = rel_string .. "@es" end
    local id = -1
    local len = 0
    if vocab_map[rel_string] then
        id = vocab_map[rel_string]
        len = 1
        in_vocab = in_vocab + 1
    else
        out_vocab = out_vocab + 1
    end
    local pattern_tensor = torch.Tensor({id})
    return pattern_tensor, len
end

--- process a single line from a candidate file ---
local function process_line(line, vocab_map, dictionary)
    local query_id, tac_rel, sf_2, doc_info, start_1, end_1, start_2, end_2, pattern_rel
    = string.match(line, "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)")

    if params.normalizeDigits then pattern_rel = pattern_rel:gsub("%^a", "") end

    local tac_tensor = torch.Tensor({vocab_map[tac_rel] or 1})

    -- we only want tokens between the two args
    local start_idx = tonumber(end_1)
    local end_idx = tonumber(start_2)
    local arg1_first = true
    if (start_idx > end_idx) then
        start_idx, end_idx, arg1_first = tonumber(end_2), tonumber(start_1), false
    end

    local pattern_tensor, seq_len
    if params.relations then
        pattern_tensor, seq_len = rel_tensor(arg1_first, pattern_rel, vocab_map, start_idx, end_idx, params.fullPath)
    else
        pattern_tensor, seq_len = token_tensor(arg1_first, pattern_rel, vocab_map, dictionary, start_idx, end_idx, params.fullPath)
    end

    pattern_tensor = pattern_tensor:view(1, pattern_tensor:size(1))
    tac_tensor = tac_tensor:view(1, tac_tensor:size(1))
    local out_line = query_id .. '\t' .. tac_rel .. '\t' .. sf_2 .. '\t' .. doc_info .. '\t'
            .. start_1 .. '\t' .. end_1 .. '\t' .. start_2 .. '\t' .. end_2 .. '\t'

    return out_line, pattern_tensor, tac_tensor, seq_len
end

--- process the candidate file and convert to torch ---
local function process_file(vocab_map, dictionary)
    local line_num = 0
    local max_seq = 0
    local data = {}
    print('Processing data')
    for line in io.lines(params.candidates) do
        local out_line, pattern_tensor, tac_tensor, seq_len = process_line(line, vocab_map, dictionary)
        max_seq = math.max(seq_len, max_seq)
        if not data[seq_len] then data[seq_len] = {out_line={}, pattern_tensor={}, tac_tensor={}} end
        local seq_len_data = data[seq_len]
        table.insert(seq_len_data.out_line, out_line)
        table.insert(seq_len_data.pattern_tensor, pattern_tensor)
        table.insert(seq_len_data.tac_tensor, tac_tensor)
        line_num = line_num + 1
        if line_num % 10000 == 0 then io.write('\rline : ' .. line_num); io.flush() end
    end
    print ('\rProcessed ' .. line_num .. ' lines')
    return data, max_seq
end

-- TODO this only works for uschema right now
local function score_tac_relation(text_encoder, kb_rel_table, pattern_tensor, tac_tensor)
    local tac_encoded = kb_rel_table:forward(to_cuda(tac_tensor)):clone()
    local pattern_encoded = text_encoder:forward(to_cuda(pattern_tensor)):clone()

    if tac_encoded:dim() == 3 then tac_encoded = tac_encoded:view(tac_encoded:size(1), tac_encoded:size(3)) end
    if pattern_encoded:dim() == 3 then pattern_encoded = pattern_encoded:view(pattern_encoded:size(1), pattern_encoded:size(3)) end
    local x = { tac_encoded, pattern_encoded }

    local score = to_cuda(nn.CosineDistance())(x):double()
    --    local score = to_cuda(nn.Sum(2))(to_cuda(nn.CMulTable())(x)):double()
    return score
end

--- score the data returned by process_file ---
local function score_data(data, max_seq, text_encoder, kb_rel_table)
    print('Scoring data')
    -- open output file to write scored candidates file
    local out_file = io.open(params.outFile, "w")
    for seq_len = 1, math.min(max_seq, params.maxSeq) do
        if data[seq_len] then
            io.write('\rseq length : ' .. seq_len); io.flush()
            local seq_len_data = data[seq_len]
            --- batch
--            local start = 1
--            while start <= #seq_len_data do
            local pattern_tensor = nn.JoinTable(1)(seq_len_data.pattern_tensor)
            local tac_tensor = nn.JoinTable(1)(seq_len_data.tac_tensor)
            local scores = score_tac_relation(text_encoder, kb_rel_table, pattern_tensor, tac_tensor)
            local out_lines = seq_len_data.out_line
            for i = 1, #out_lines do
                local score = scores[i] > params.threshold and scores[i] or 0
                out_file:write(out_lines[i] .. score .. '\n')
            end
        end
    end
    out_file:close()
end

---- main

local model = torch.load(params.model)

local kb_rel_table = to_cuda(model.kb_rel_table ~= nil and model.kb_rel_table or model.encoder)
local text_encoder = to_cuda(model.text_encoder ~= nil and model.text_encoder or model.encoder)
kb_rel_table:evaluate()
text_encoder:evaluate()

-- load the vocab map to memory
local vocab_map = {}
for line in io.lines(params.vocabFile) do
    local token, id = string.match(line, "([^\t]+)\t([^\t]+)")
    if token then vocab_map[token] = tonumber(id) end
end
local dictionary = {}
if params.dictionary ~= '' then
    for line in io.lines(params.dictionary) do
        -- space seperated
        local en, es = string.match(line, "([^\t]+) ([^\t]+)")
        dictionary[es] = en
    end
end


local data, max_seq = process_file(vocab_map, dictionary)
score_data(data, max_seq, text_encoder, kb_rel_table)

print ('\nDone, found ' .. in_vocab .. ' in vocab tokens and ' .. out_vocab .. ' out of vocab tokens.')