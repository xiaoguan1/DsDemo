--[[
# 红黑树（Red-Black Tree）
## 一、是什么
红黑树是一种 自平衡二叉搜索树 ，通过给每个节点附加「红色/黑色」颜色信息，配合旋转和变色，保证树大致平衡，从而让查找、插入、删除都维持 O(log n) 。

因为平衡要求比 AVL 树宽松， 插入/删除时旋转次数更少 ，在频繁增删的场景性能更好。

## 二、五条性质（面试必背）
1. 每个节点要么是红色，要么是黑色。
2. 根节点是黑色。
3. 叶子（NIL / 空节点）是黑色。
4. 红色节点的两个子节点都是黑色 （不能出现连续红色）。
5. 从任一节点到其所有后代叶子的路径上， 黑色节点数量相同 （黑高一致）。 由 4、5 推出：最长路径（红黑交替）最多不超过最短路径（全黑）的 2 倍，因此是「近似平衡」，树高 ≤ 2·log(n+1)。
## 三、复杂度
操作 平均/最坏 查找 O(log n) 插入 O(log n) 删除 O(log n)

## 三、复杂度
    查找 O(log n) 
    插入 O(log n)
    删除 O(log n)

## 四、实际应用（可关联你的项目）
- `epoll` 内部用红黑树管理所有监听的 fd —— 和你熟悉的 skynet socket 层正好相关。
- C++`std::map/std::set` 、Java`TreeMap` 、Linux CFS 调度器、nginx 定时器。


]]

local RedBlackTree = {}
RedBlackTree.__index = RedBlackTree

-- 新节点，默认红色，左右与父指针先指向哨兵 nil 节点
local function new_node(key, val, nil_node)
    return {
        -- 键值对
        key    = key,
        val    = val,

        -- 红黑标记， 新节点默认红色 （这是红黑树插入修复的起点）
        color  = "RED",

        -- `left` /`right` /`parent` ：三个指针，初始都指向哨兵节点
        left   = nil_node,
        right  = nil_node,
        parent = nil_node,
    }
end

function RedBlackTree.new()
    local self = setmetatable({}, RedBlackTree)
    -- 哨兵节点（所有空叶子共用一个），视为黑色
    --[[
        所有「空叶子」都指向这同一个`nd` ，它被当作黑色叶子。这样做的好处是：
            空指针判断统一用`x ~= self.nil_node`
            旋转/遍历时不用反复判空，代码大幅简化
        `root` 初始也指向`nil` （空树），`size` 记录节点数。
    ]]
    local nd = { color = "BLACK" }
    nd.left, nd.right, nd.parent = nd, nd, nd
    self.nil_node  = nd
    self.root = nd
    self.size = 0
    return self
end


--[[
    旋转：`left_rotate` /`right_rotate` 是红黑树维持平衡的基本操作，本质是 在不破坏 BST 性质（左小右大）的前提下，调整父子关系 。
    以左旋为例，`x.right = y.left` （把 y 的左子树挂到 x 的右边）→ 调整 y 与 x.parent 的关系 → 最后`y.left = x` 。右旋是它的镜像。这两段是纯指针搬运，不涉及颜色。
]]

-- 左旋：以 x 为轴，把右孩子 y 转上来
local function left_rotate(self, x)
    local y = x.right
    x.right = y.left
    if y.left ~= self.nil_node then y.left.parent = x end
    y.parent = x.parent
    if x.parent == self.nil_node then
        self.root = y
    elseif x == x.parent.left then
        x.parent.left = y
    else
        x.parent.right = y
    end
    y.left = x
    x.parent = y
end

-- 右旋：左旋的镜像
local function right_rotate(self, y)
    local x = y.left
    y.left = x.right
    if x.right ~= self.nil_node then x.right.parent = y end
    x.parent = y.parent
    if y.parent == self.nil_node then
        self.root = x
    elseif y == y.parent.left then
        y.parent.left = x
    else
        y.parent.right = x
    end
    x.right = y
    y.parent = x
end

-- 插入后修复红黑性质
function RedBlackTree:_insert_fixup(z)
    while z.parent.color == "RED" do          -- 父节点是红，违反性质4
        if z.parent == z.parent.parent.left then
            local uncle = z.parent.parent.right
            if uncle.color == "RED" then
                -- 情况1：叔叔是红 -> 变色上移
                z.parent.color = "BLACK"
                uncle.color = "BLACK"
                z.parent.parent.color = "RED"
                z = z.parent.parent
            else
                if z == z.parent.right then
                    -- 情况2：z 是右孩子 -> 左旋转成情况3
                    z = z.parent
                    left_rotate(self, z)
                end
                -- 情况3：叔叔黑且 z 是左孩子 -> 变色 + 右旋
                z.parent.color = "BLACK"
                z.parent.parent.color = "RED"
                right_rotate(self, z.parent.parent)
            end
        else
            -- 与上面完全对称
            local uncle = z.parent.parent.left
            if uncle.color == "RED" then
                z.parent.color = "BLACK"
                uncle.color = "BLACK"
                z.parent.parent.color = "RED"
                z = z.parent.parent
            else
                if z == z.parent.left then
                    z = z.parent
                    right_rotate(self, z)
                end
                z.parent.color = "BLACK"
                z.parent.parent.color = "RED"
                left_rotate(self, z.parent.parent)
            end
        end
    end
    self.root.color = "BLACK"                 -- 性质2：根恒为黑
end

--[[
    插入分两步：
        第一步`insert` （第 106~126 行） ：像普通 BST 一样从根往下找位置，用`y` 记录父节点，把新节点挂上去，颜色置红，然后调用`_insert_fixup` 修复。
        第二步`_insert_fixup` （第 63~104 行） ：修复「红节点不能有红孩子」这条性质。循环条件是`z.parent.color == "RED"` （说明出现了 连续两个红节点 ）。根据「叔叔节点」的颜色分三种情况：

        情况1 红 父、叔变黑，祖父变红，问题上移到祖父 
        情况2 黑，z 是右孩子 左旋父节点，转成情况3 
        情况3 黑，z 是左孩子 父变黑、祖父变红，右旋祖父
]]

function RedBlackTree:insert(key, val)
    local z = new_node(key, val, self.nil_node)
    local y = self.nil_node
    local x = self.root
    while x ~= self.nil_node do                    -- 找插入位置
        y = x
        if z.key < x.key then x = x.left else x = x.right end
    end
    z.parent = y
    if y == self.nil_node then
        self.root = z
    elseif z.key < y.key then
        y.left = z
    else
        y.right = z
    end
    z.left, z.right = self.nil_node, self.nil_node
    z.color = "RED"
    self.size = self.size + 1
    self:_insert_fixup(z)
end

-- 标准的 BST 查找：`key` 相等返回`val` ，小于走左子树，大于走右子树，走到哨兵节点说明没找到返回`nil` 。
function RedBlackTree:get(key)
    local x = self.root
    while x ~= self.nil_node do
        if key == x.key then return x.val end
        if key < x.key then x = x.left else x = x.right end
    end
    return nil
end

-- 中序遍历（升序输出） 
-- 递归中序遍历（左 → 根 → 右），因为红黑树是 BST，所以会 按 key 升序 依次回调`f(key, val, color)` 。
local function inorder(node, nd, f)
    if node == nd then return end
    inorder(node.left, nd, f)
    f(node.key, node.val, node.color)
    inorder(node.right, nd, f)
end

function RedBlackTree:forEach(f)
    inorder(self.root, self.nil_node, f)
end

return RedBlackTree


-- local RBTree = require "red_black_tree"

-- local t = RBTree.new()
-- t:insert(30, "a")
-- t:insert(20, "b")
-- t:insert(40, "c")
-- t:insert(10, "d")   -- 触发了插入修复（旋转/变色）
-- t:insert(50, "e")

-- print(t:get(20))    -- b
-- print("size =", t.size)          -- 5
-- print("root =", t.root.key)      -- 平衡后根节点
-- t:forEach(function(k, v, c)
--     print(k, v, c)  -- 按 key 升序遍历
-- end)