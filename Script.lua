local url = "https://discord.com/api/webhooks/1390380206883209387/m2dbLn_Yq8H8f2UGF6MBgk1e2lvk_yu4SbszTMfz_vWdFAZnk3_QWPCRx_nUkZtDFgvF"
function SendMessage(url, message)
    local http = game:GetService("HttpService")
    local headers = {
        ["Content-Type"] = "application/json"
    }
    local data = {
        ["content"] = message
    }
    local body = http:JSONEncode(data)
    local response = request({
        Url = url,
        Method = "POST",
        Headers = headers,
        Body = body
    })
    print("Sent")
end

while task.wait(60) do
    SendMessage(url, "Active, Grinding")
    local response = request({
        Url = "https://raw.githubusercontent.com/Zyn-ic/MM2-AutoFarm/refs/heads/main/FullAuto/Source.lua",
        Method = "GET",
    })
    loadstring(response.Body)()
    print("This script is running every minute!") 
end
