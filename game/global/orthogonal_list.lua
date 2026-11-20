
OlList = {}

function OlList:New()
	local o = {
		vertexList = {		-- 向量列表
			-- [id] = {
			-- 	vertexData = ...,	-- 顶点数据
			-- 	firstin = {			-- 入弧度
			-- 		headvex = ...,	-- 弧的头顶点
			-- 		tailvex = ...,	-- 弧的尾顶点
			-- 		hlink = ...,
			-- 		tlink = ...,
			-- 	},
			-- 	firstout = ...,		-- 出弧度
			-- },
		},
		numVertexs = 0,		-- 有向图的顶点数量
		numArcs = 0,		-- 有向图的弧度数量
	}
	setmetatable(o, {__index = OlList})
	return o
end

-- fVex：弧头
-- tVex：弧尾
-- weight：权重
function OlList:UpdateVex(fVex, tVex, weight)
	-- 有向图中：fVex -> tVex	出度
	-- 无向图：fVex <-> tVex	即是出度也是入度
end
