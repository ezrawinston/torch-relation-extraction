--
-- User: pat
-- Date: 9/1/15
--

require 'torch'
require 'optim'
require 'RelationEncoderModel.lua'

local TransEEncoder, parent = torch.class('TransEEncoder', 'RelationEncoderModel')

function TransEEncoder:__init(params, rel_table, encoder, squeeze_rel)
    self.__index = self
    self.params = params
    self.squeeze_rel = squeeze_rel or false
    self.encoder = encoder
    self.train_data = self:load_entity_data(params.train)

    local net, ent_table, scorer = self:build_network(params, self.train_data.num_ents, encoder)
    self.net = net
    self.crit = self:to_cuda(nn.MarginRankingCriterion(params.margin))
    self.scorer = scorer
    self.rel_table = rel_table
    self.ent_table = ent_table
end


function TransEEncoder:build_network(params, num_ents, encoder)
    -- seperate lookup tables for entity pairs and relations
    local pos_e1_table = nn.LookupTable(num_ents, params.embeddingDim)
    -- preload entity pairs
    if params.loadEpEmbeddings ~= '' then pos_e1_table.weight = (self:to_cuda(torch.load(params.loadEpEmbeddings)))
    else pos_e1_table.weight = torch.rand(num_ents, params.embeddingDim):add(-.5):mul(0.1)
    end
    local pos_e2_table = pos_e1_table:clone()
    local neg_e1_table = pos_e1_table:clone()
    local neg_e2_table = pos_e1_table:clone()

    -- load the entities and relation
    local loading_par_table = nn.ParallelTable()
    loading_par_table:add(pos_e2_table)
    loading_par_table:add(pos_e1_table)
    loading_par_table:add(encoder)
    loading_par_table:add(neg_e1_table)
    loading_par_table:add(neg_e2_table)

    -- layers to compute score for the positive and negative samples
    -- select e1 + rel
    local pos_e1_rel = nn.Sequential()
    pos_e1_rel:add(nn.NarrowTable(2, 2))
    pos_e1_rel:add(nn.CAddTable())
    -- select e2
    local pos_e2 = nn.Sequential()
    pos_e2:add(nn.SelectTable(1))

    local pos_select = nn.ConcatTable()
    pos_select:add(pos_e1_rel)
    pos_select:add(pos_e2)

    local pos_score = nn.Sequential()
    pos_score:add(pos_select)
    pos_score:add(nn.PairwiseDistance(params.p))

    -- select e1 + rel
    local neg_e1_rel = nn.Sequential()
    neg_e1_rel:add(nn.NarrowTable(3, 2))
    neg_e1_rel:add(nn.CAddTable())
    -- select e2
    local neg_e2 = nn.Sequential()
    neg_e2:add(nn.SelectTable(5))

    local neg_select = nn.ConcatTable()
    neg_select:add(neg_e1_rel)
    neg_select:add(neg_e2)

    local neg_score = nn.Sequential()
    neg_score:add(neg_select)
    neg_score:add(nn.PairwiseDistance(params.p))

    -- add the parallel scores together into one sequential network
    local net = nn.Sequential()
    net:add(loading_par_table)
    local concat_table = nn.ConcatTable()
    concat_table:add(pos_score)
    concat_table:add(neg_score)
    net:add(concat_table)

    -- put the networks on cuda
    self:to_cuda(net)

    -- need to do param sharing after tocuda
    neg_e1_table:share(neg_e2_table, 'weight', 'bias', 'gradWeight', 'gradBias')
    pos_e2_table:share(neg_e1_table, 'weight', 'bias', 'gradWeight', 'gradBias')
    pos_e1_table:share(pos_e2_table, 'weight', 'bias', 'gradWeight', 'gradBias')
    return net, pos_e1_table, pos_score
end



----- TRAIN -----
function TransEEncoder:gen_subdata_batches(sub_data, batches, max_neg, shuffle)
    local start = 1
    local rand_order = shuffle and torch.randperm(sub_data.ep:size(1)):long() or torch.range(1, sub_data.ep:size(1)):long()
    while start <= sub_data.ep:size(1) do
        local size = math.min(self.params.batchSize, sub_data.ep:size(1) - start + 1)
        local batch_indices = rand_order:narrow(1, start, size)
        local pos_e1_batch = sub_data.e1:index(1, batch_indices)
        local pos_e2_batch = sub_data.e2:index(1, batch_indices)
        local neg_ent_batch = self:to_cuda(torch.rand(size):mul(max_neg):floor():add(1))
        --randomly negative sample either e1 or e2
        local neg_e1_batch, neg_e2_batch

        local neg_e1_batch = self:to_cuda(torch.rand(size):mul(max_neg):floor():add(1))
        local neg_e2_batch = self:to_cuda(torch.rand(size):mul(max_neg):floor():add(1))
--        if torch.uniform() > 0.5 then
--            neg_e1_batch, neg_e2_batch = pos_e1_batch:clone(), neg_ent_batch
--        else
--            neg_e1_batch, neg_e2_batch = neg_ent_batch, pos_e2_batch:clone()
--        end
        -- randomly 0 out half of the pos e1's
--        local choose_head_tail = self:to_cuda(torch.rand(size):gt(0.5):double())
--        local neg_e1_batch = pos_e1_batch:clone():cmul(choose_head_tail)
--        -- replace the 0 indicies with negative samples
--        neg_e1_batch:add(neg_ent_batch:clone():cmul(self:to_cuda(neg_e1_batch:eq(0):double())))
--        -- need to 0 out the opposites of e1
--        local neg_e2_batch = pos_e2_batch:clone():cmul(self:to_cuda(choose_head_tail:eq(0):double()))
--        neg_e2_batch:add(neg_ent_batch:clone():cmul(self:to_cuda(neg_e2_batch:eq(0):double())))


        local rel_batch = self.params.testing and sub_data.rel:index(1, batch_indices) or sub_data.seq:index(1, batch_indices)
        if self.squeeze_rel then rel_batch = rel_batch:squeeze() end
        local batch = { pos_e2_batch, pos_e1_batch, rel_batch, neg_e1_batch, neg_e2_batch }
        table.insert(batches, { data = batch, label = -1 })
        start = start + size
    end
end


function TransEEncoder:gen_training_batches(data)
    local batches = {}
    if #data > 0 then
        for seq_size = 1, self.params.maxSeq and math.min(self.params.maxSeq, #data) or #data do
            local sub_data = data[seq_size]
            if sub_data and sub_data.ep then self:gen_subdata_batches(sub_data, batches, data.num_ents, true) end
        end
    else
        self:gen_subdata_batches(data, batches, data.num_ents, true)
    end
    return batches
end

function TransEEncoder:regularize()
    -- make norms of entity vectors exactly 1
    self.ent_table.weight:cdiv(self.ent_table.weight:norm(2, 2):expandAs(self.ent_table.weight))
--    self.rel_table.weight:renorm(2, 2, 3.0)
--    self.ent_table.weight:renorm(2, 2, 3.0)
end


function TransEEncoder:optim_update(net, criterion, x, y, parameters, grad_params, opt_config, opt_state, epoch)
    local err, df_do
    local margin = self.params.margin
    local function fEval(parameters)
        if parameters ~= parameters then parameters:copy(parameters) end
        net:zeroGradParameters()
        local pred = net:forward(x)

--        print('before', pred[1][1], pred[2][1])
--        err, df_do = criterion(pred, y)
--        err = err:mean()

        local theta = pred[1]:clone():fill(self.params.margin) + pred[1] - pred[2]
        local mask = theta:clone():ge(theta, 0)
        theta:cmul(mask)
        local prob = theta:clone():fill(1):cdiv(torch.exp(-theta):add(1))
        err = torch.log(prob):mean()
        local step = (prob:clone():fill(1) - prob)
        df_do = { -step, step }

        net:backward(x, df_do)
        if self.params.clipGrads then
            local grad_norm = grad_params:norm(2)
            if grad_norm > 1 then grad_params = grad_params:div(grad_norm) end
        end
        if self.params.freezeEp >= epoch then self.ent_table:zeroGradParameters() end
        if self.params.freezeRel >= epoch then self.rel_table:zeroGradParameters() end
        return err, grad_params
    end
    optim[self.params.optimMethod](fEval, parameters, opt_config, opt_state)
--    local pred = net:forward(x)
--    print('after', pred[1][1], pred[2][1], grad_params:norm(2))
    -- TODO, better way to handle this
    if self.params.regularize then self:regularize() end
    return err
end

--- - Evaluate ----
function TransEEncoder:evaluate()
    if self.params.test ~= '' then
        self:map(self.params.test, false)
    end
end


function TransEEncoder:score_subdata(sub_data)
    local batches = {}
    self:gen_subdata_batches(sub_data, batches, 0, false)

    local scores = {}
    for i = 1, #batches do
        local e2_batch, e1_batch, rel_batch, _, _ = unpack(batches[i].data)
        local encoded_rel = self.encoder:forward(self:to_cuda(rel_batch)):clone()
        local e1 = self.ent_table(self:to_cuda(e1_batch:contiguous():view(e1_batch:size(1), 1))):clone()
        local e2 = self.ent_table(self:to_cuda(e2_batch:contiguous():view(e2_batch:size(1), 1))):clone()
        local x = { e2, e1, encoded_rel }
        x = {
            x[1]:view(x[2]:size(1), x[2]:size(3)),
            x[2]:view(x[2]:size(1), x[2]:size(3)),
            x[3]:view(x[2]:size(1), x[2]:size(3))
        }
        local score = self.scorer(x)
        table.insert(scores, score)
    end
    return scores, sub_data.label:view(sub_data.label:size(1))

end