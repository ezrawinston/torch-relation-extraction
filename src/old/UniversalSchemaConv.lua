--
-- User: pat
-- Date: 8/26/15
--
package.path = package.path .. ";src/?.lua"

require 'CmdArgs'


local params = CmdArgs:parse(arg)
torch.manualSeed(0)

print('Using ' .. (params.gpuid >= 0 and 'GPU' or 'CPU'))
if params.gpuid >= 0 then require 'cunn'; cutorch.manualSeed(0); cutorch.setDevice(params.gpuid + 1) else require 'nn' end


local function cnn_encoder(params)
    local train_data = torch.load(params.train)

    local inputSize = params.wordDim > 0 and params.wordDim or (params.relDim > 0 and params.relDim or params.embeddingDim)
    local outputSize = params.relDim > 0 and params.relDim or params.embeddingDim

    local rel_size = train_data.num_tokens
    local rel_table
    -- never update word embeddings, these should be preloaded
    if params.noWordUpdate then
        require 'nn-modules/NoUpdateLookupTable'
        rel_table = nn.NoUpdateLookupTable(rel_size, inputSize)
    else
        rel_table = nn.LookupTable(rel_size, inputSize)
    end

    -- initialize in range [-.1, .1]
    rel_table.weight = torch.rand(rel_size, inputSize):add(-.5):mul(0.1)
    if params.loadRelEmbeddings ~= '' then
        rel_table.weight = (torch.load(params.loadRelEmbeddings))
    end

    local encoder = nn.Sequential()
    if params.wordDropout > 0 then
        require 'nn-modules/WordDropout'
        encoder:add(nn.WordDropout(params.wordDropout, 1))
    end
    encoder:add(rel_table)
    if params.dropout > 0.0 then
        encoder:add(nn.Dropout(params.dropout))
    end
    if (params.convWidth > 1) then encoder:add(nn.Padding(1,1,-1)) end
    if (params.convWidth > 2) then encoder:add(nn.Padding(1,-1,-1)) end
    encoder:add(nn.TemporalConvolution(inputSize, outputSize, params.convWidth))
    encoder:add(nn.Tanh())
    local pool_layer = params.poolLayer ~= '' and params.poolLayer or 'Max'
    encoder:add(nn[pool_layer](2))

    return encoder, rel_table
end

local encoder, rel_table = cnn_encoder(params)

local model
if params.entityModel then
    require 'UniversalSchemaEntityEncoder'
    model = UniversalSchemaEntityEncoder(params, rel_table, encoder)
else
    require 'UniversalSchemaEncoder'
    model = UniversalSchemaEncoder(params, rel_table, encoder)
end

print(model.net)
model:train()
if params.saveModel ~= '' then  model:save_model(params.numEpochs) end



