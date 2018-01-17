require"socketssl"
module(...,package.seeall)

--[[
功能需求：
1、数据网络准备就绪后，连接https后台
2、连接成功后，每隔20秒钟发送一次GET命令到后台
3、与后台保持长连接，断开后主动再去重连，连接成功仍然按照第2条发送数据
4、收到后台的数据时，在rcv函数中打印出来
测试时请搭建自己的服务器，并且修改下面的PROT，ADDR，PORT，支持域名和IP地址

此例子为长连接，只要是软件上能够检测到的网络异常，可以自动去重新连接
]]

local ssub,schar,smatch,sbyte,slen = string.sub,string.char,string.match,string.byte,string.len
--测试时请搭建自己的服务器
local SCK_IDX,PROT,ADDR,PORT = 1,"TCP","36.7.87.100",4433
--linksta:与后台的socket连接状态
local linksta
--一个连接周期内的动作：如果连接后台失败，会尝试重连，重连间隔为RECONN_PERIOD秒，最多重连RECONN_MAX_CNT次
--如果一个连接周期内都没有连接成功，则等待RECONN_CYCLE_PERIOD秒后，重新发起一个连接周期
--如果连续RECONN_CYCLE_MAX_CNT次的连接周期都没有连接成功，则重启软件
local RECONN_MAX_CNT,RECONN_PERIOD,RECONN_CYCLE_MAX_CNT,RECONN_CYCLE_PERIOD = 3,5,3,20
--reconncnt:当前连接周期内，已经重连的次数
--reconncyclecnt:连续多少个连接周期，都没有连接成功
--一旦连接成功，都会复位这两个标记
--conning:是否在尝试连接
local reconncnt,reconncyclecnt,conning = 0,0

local sndata = "GET / HTTP/1.1\r\nHost: 36.7.87.100\r\nConnection: keep-alive\r\n\r\n"

--[[
函数名：print
功能  ：打印接口，此文件中的所有打印都会加上test前缀
参数  ：无
返回值：无
]]
local function print(...)
	_G.print("test",...)
end

--[[
函数名：snd
功能  ：调用发送接口发送数据
参数  ：
        data：发送的数据，在发送结果事件处理函数ntfy中，会赋值到item.data中
		para：发送的参数，在发送结果事件处理函数ntfy中，会赋值到item.para中 
返回值：调用发送接口的结果（并不是数据发送是否成功的结果，数据发送是否成功的结果在ntfy中的SEND事件中通知），true为成功，其他为失败
]]
function snd(data,para)
	return socketssl.send(SCK_IDX,data,para)
end


--[[
函数名：httpget
功能  ：发送GET命令到后台
参数  ：无
返回值：无
]]
function httpget()
	print("httpget",linksta)
	if linksta then
		snd(sndata,"HTTPGET")
	end
end


--[[
函数名：httpgetcb
功能  ：GET命令发送回调，启动定时器，20秒钟后再次发送GET命令
参数  ：		
		item：table类型，{data=,para=}，消息回传的参数和数据，例如调用socketssl.send时传入的第2个和第3个参数分别为dat和par，则item={data=dat,para=par}
		result： bool类型，发送结果，true为成功，其他为失败
返回值：无
]]
function httpgetcb(item,result)
	print("httpgetcb",linksta)
	if linksta then
		sys.timer_start(httpget,20000)
	end
end


--[[
函数名：sndcb
功能  ：数据发送结果处理
参数  ：          
		item：table类型，{data=,para=}，消息回传的参数和数据，例如调用socketssl.send时传入的第2个和第3个参数分别为dat和par，则item={data=dat,para=par}
		result： bool类型，发送结果，true为成功，其他为失败
返回值：无
]]
local function sndcb(item,result)
	print("sndcb",item.para,result)
	if not item.para then return end
	if item.para=="HTTPGET" then
		httpgetcb(item,result)
	end
end


--[[
函数名：reconn
功能  ：重连后台处理
        一个连接周期内的动作：如果连接后台失败，会尝试重连，重连间隔为RECONN_PERIOD秒，最多重连RECONN_MAX_CNT次
        如果一个连接周期内都没有连接成功，则等待RECONN_CYCLE_PERIOD秒后，重新发起一个连接周期
        如果连续RECONN_CYCLE_MAX_CNT次的连接周期都没有连接成功，则重启软件
参数  ：无
返回值：无
]]
local function reconn()
	print("reconn",reconncnt,conning,reconncyclecnt)
	--conning表示正在尝试连接后台，一定要判断此变量，否则有可能发起不必要的重连，导致reconncnt增加，实际的重连次数减少
	if conning then return end
	--一个连接周期内的重连
	if reconncnt < RECONN_MAX_CNT then		
		reconncnt = reconncnt+1
		socketssl.disconnect(SCK_IDX)
	--一个连接周期的重连都失败
	else
		reconncnt,reconncyclecnt = 0,reconncyclecnt+1
		if reconncyclecnt >= RECONN_CYCLE_MAX_CNT then
			sys.restart("connect fail")
		end
		link.shut()
	end
end

--[[
函数名：ntfy
功能  ：socket状态的处理函数
参数  ：
        idx：number类型，socketssl.lua中维护的socket idx，跟调用socketssl.connect时传入的第一个参数相同，程序可以忽略不处理
        evt：string类型，消息事件类型
		result： bool类型，消息事件结果，true为成功，其他为失败
		item：table类型，{data=,para=}，消息回传的参数和数据，目前只是在SEND类型的事件中用到了此参数，例如调用socketssl.send时传入的第2个和第3个参数分别为dat和par，则item={data=dat,para=par}
返回值：无
]]
function ntfy(idx,evt,result,item)
	print("ntfy",evt,result,item)
	--连接结果（调用socketssl.connect后的异步事件）
	if evt == "CONNECT" then
		conning = false
		--连接成功
		if result then
			reconncnt,reconncyclecnt,linksta = 0,0,true
			--停止重连定时器
			sys.timer_stop(reconn)
			--发送GET命令到后台
			httpget()
		--连接失败
		else
			--RECONN_PERIOD秒后重连
			sys.timer_start(reconn,RECONN_PERIOD*1000)
		end	
	--数据发送结果（调用socketssl.send后的异步事件）
	elseif evt == "SEND" then
		if item then
			sndcb(item,result)
		end
		--发送失败，RECONN_PERIOD秒后重连后台，不要调用reconn，此时socket状态仍然是CONNECTED，会导致一直连不上服务器
		--if not result then sys.timer_start(reconn,RECONN_PERIOD*1000) end
		if not result then socketssl.disconnect(idx) end
	--连接被动断开
	elseif evt == "STATE" and result == "CLOSED" then
		linksta = false
		sys.timer_stop(httpget)
		sys.timer_start(reconn,RECONN_PERIOD*1000)
	--连接主动断开（调用link.shut后的异步事件）
	elseif evt == "STATE" and result == "SHUTED" then
		linksta = false
		sys.timer_stop(httpget)
		socketssl.disconnect(idx)
	--连接主动断开（调用socketssl.disconnect后的异步事件）
	elseif evt == "DISCONNECT" then
		linksta = false
		sys.timer_stop(httpget)
		connect()
	end
	--其他错误处理，断开数据链路，重新连接
	if smatch((type(result)=="string") and result or "","ERROR") then
		socketssl.disconnect(idx)
	end
end

--[[
函数名：rcv
功能  ：socket接收数据的处理函数
参数  ：
        idx ：socketssl.lua中维护的socket idx，跟调用socketssl.connect时传入的第一个参数相同，程序可以忽略不处理
        data：接收到的数据
返回值：无
]]
function rcv(idx,data)
	print("rcv",data)
end

--[[
函数名：connect
功能  ：创建到后台服务器的连接；
        如果数据网络已经准备好，会理解连接后台；否则，连接请求会被挂起，等数据网络准备就绪后，自动去连接后台
		ntfy：socket状态的处理函数
		rcv：socket接收数据的处理函数
参数  ：无
返回值：无
]]
function connect()
	--verifysvrcerts：校验服务器端证书的CA证书文件 (Base64编码 X.509格式)
	socketssl.connect(SCK_IDX,PROT,ADDR,PORT,ntfy,rcv,true,{verifysvrcerts={"ca.crt"}})
	conning = true
end

connect()
