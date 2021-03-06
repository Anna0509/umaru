require 'image'
require 'codec'
require 'normalizer'
local lfs = require 'lfs'
local utf8 = require 'utf8'

Loader = {
	samples = {},
	training = {},
	testing = {},
	weights = nil,
	p = nil,
	codec_table = {},
	codec_inv = {},
	codec_size = 0,
	codec_obj = nil,
	threshold = 3,
	lambda = 3.0,
	pos = 1,
	target_height = 32
}

setmetatable(Loader, {
	__call = 
		function (cls, ...)
			return cls:new(...)
		end
})

function Loader:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end

function Loader:shuffle()
	for i = 1, #self.samples do
		local j = torch.random(#self.samples)
		self.samples[i], self.samples[j]= self.samples[j], self.samples[i]
	end
end

function Loader:__split(rate)
	assert(rate <= 1 and rate > 0, "", "invalid rate")
	ntrain = math.floor(#self.samples * rate)
	ntest = #self.samples - ntrain
	
	for i = 1, #self.samples do
		if i <= ntrain then
			table.insert(self.training, self.samples[i])
		else
			table.insert(self.testing, self.samples[i])
		end
	end
end

function Loader:targetHeight(target_height)
	self.target_height = target_height or self.target_height
	return targetHeight
end

function Loader:__getNormalizedImage(src)
	local defaultTensorType = torch.getdefaulttensortype()
	torch.setdefaulttensortype('torch.DoubleTensor')
	local im = image.load(src, 1)

	if im:dim() == 3 then
		im = im[1]
	end

	local output = torch.DoubleTensor()

	local w = im:size()[2]
	local h = im:size()[1]

	local ones = torch.ones(h, w)

	im = ones - im
	normalizer.normalize(im:double(), output, self.target_height)
	-- image.save("normalized.png", output:float())

	--local target_width = self.target_height / h * w

	--output = image.scale(im, target_width, self.target_height)

	-- image.save("scaled.png", output)
	torch.setdefaulttensortype(defaultTensorType)
	return output
end

function Loader:load(file, rate)
	self.samples = {}
	local f = assert(io.open(file, "r"))
	for line in f:lines() do
		local src = line

		if lfs.attributes(src, "size") < 200 then
			print("found invalid sample " .. src)
			goto continue
		end


		local gt = src:gsub("[.].*", ".gt.txt")
		local cf = io.open(gt, "r")

		if cf == nil then
			print("ground truth not found " .. gt)
			goto continue
		end

		local gt = cf:read("*line")
		cf:close()
		
		for _, c, _ in utf8.iter(gt) do
			if self.codec_table[c] == nil then
				self.codec_size = self.codec_size + 1
				self.codec_table[c] = self.codec_size
			end
			
		end
		
		table.insert(self.samples, {src = src, gt = gt, img = nil})

		::continue::
	end
	f:close()
	
	for k, v in pairs(self.codec_table) do
		self.codec_inv[v] = k
	end
	
	self.codec_obj = nil
	self.weights = nil
	
	rate = rate or 1
	self:__split(rate)
	
	-- return self.samples
end

function Loader:loadTesting(file)
	local f = assert(io.open(file, "r"))
	for line in f:lines() do
		local src = line

		if lfs.attributes(src, "size") < 200 then
			print("found invalid sample " .. src)
			goto continue
		end

		local gt = src:gsub("[.].*", ".gt.txt")
		local cf = io.open(gt, "r")

		if cf == nil then
			print("found invalid sample " .. src)
			goto continue
		end

		local gt = cf:read("*line")
		cf:close()
		
		for _, c, _ in utf8.iter(gt) do
			if self.codec_table[c] == nil then
				print("there is a character that shows in testing set but not in training set.")
			end
		end
		
		local sample = {src = src, gt = gt, img = nil}

		table.insert(self.samples, sample)
		table.insert(self.testing, sample)

		::continue::
	end
	f:close()
end

function Loader:__pick(index, from)
	from = from or "training"
	
	if self[from][index].img == nil then

		t = self[from][index].src:sub(-3, -1)

		if (t == "png") then
			self[from][index].img = self:__getNormalizedImage(self[from][index].src):t()
		elseif (t == ".ft") then
			self[from][index].img = torch.load(self[from][index].src):t()
		end
		
		if false then
			self[from][index].img = self[from][index].img:cuda()
		end
	end
	
	return self[from][index]
end

function Loader:pick()
	from = from or "training"
	assert(self[from], "invalid set name.")
	
	local index = torch.random(#self[from])
	
	return self:__pick(index)
end

function Loader:pickWithWeight()
	
	if self.weights == nil then
		self.weights = torch.zeros(#self.training)
		for i, v in ipairs(self.samples) do
			self.weights[i] = math.pow(1.0 / math.max(utf8.len(v.gt), self.threshold), self.lambda)
		end
		self.weights = torch.div(self.weights, torch.sum(self.weights))
		
		self.p = torch.zeros(#self.training)
		local i = 0
		self.p:apply(function()
			i = i + 1
			return torch.normal(1.0 / self.weights[i], 1.0 / self.weights[i] / 3.0) 
		end)
	end
	local _, index = torch.min(self.p, 1)
	index = index[1]
	self.p[index] = torch.normal(1.0 / self.weights[index], 1.0 / self.weights[index] / 3.0) + 1
	
	return self:__pick(index)
end

function Loader:reset()
	self.pos = 1
end

function Loader:pickInSequential(from)
	from = from or "samples"
	if self.pos <= #self[from] then
		self.pos = self.pos + 1
		return self:__pick(self.pos - 1, from), self.pos - 1, #self[from]
	else
		return nil
	end
end

function Loader:updateWeight(lambda)
	self.lambda = lambda
	self.weights = nil
end

function Loader:codec()
	self.codec_obj = self.codec_obj or Codec:new{
		codec = self.codec_table,
		codec_inv = self.codec_inv,
		codec_size = self.codec_size
	}
	
	return self.codec_obj
end

function Loader:loadCodec(codec_file)
	self.codec_obj = Codec(torch.load(codec_file))

	return self.codec_obj
end