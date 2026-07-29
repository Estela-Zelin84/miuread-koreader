local Result = {}

function Result.annotation_pending(record)
    return type(record) == "table" and record.annotation_pending == true
end

function Result.annotation_fallback(record)
    return type(record) == "table" and record.annotation_fallback == true
end

function Result.variant_label(label, record)
    label=tostring(label or "")
    if Result.annotation_pending(record) then return label.." · 待补全" end
    if Result.annotation_fallback(record) then return label.." · 章节末尾保留" end
    return label
end

function Result.aggregate(records)
    local result={annotation_pending=false,annotation_fallback=false}
    for _,record in ipairs(records or {}) do
        if Result.annotation_pending(record) then result.annotation_pending=true end
        if Result.annotation_fallback(record) then result.annotation_fallback=true end
    end
    return result
end

function Result.state(record, pending_install)
    if pending_install == true then return "pending_install" end
    if Result.annotation_pending(record) then return "annotation_pending" end
    return "completed"
end

function Result.shelf_status(record, pending_install)
    local pending = Result.annotation_pending(record)
    local fallback = Result.annotation_fallback(record)
    if pending_install == true then
        if pending then return "等待关闭后更新 · 划线或想法待补全" end
        if fallback then return "等待关闭后更新 · 少量内容已保留在章节末尾" end
        return "等待关闭后更新"
    end
    if pending then return "已生成 · 划线或想法待补全" end
    if fallback then return "已生成 · 少量内容已保留在章节末尾" end
    return "已生成"
end

function Result.notice(title, record, pending_install)
    title = tostring(title or "未命名")
    local pending = Result.annotation_pending(record)
    local fallback = Result.annotation_fallback(record)
    if pending_install == true then
        local text = title .. "新版本已下载，关闭当前书籍后更新"
        if pending then text = text .. "；部分划线或想法待补全"
        elseif fallback then text = text .. "；少量内容已保留在章节末尾" end
        return text
    end
    if pending then
        local text = title .. "正文已生成，部分划线或想法待补全"
        if fallback then text = text .. "；少量内容已保留在章节末尾" end
        return text
    end
    if fallback then return title .. "正文已生成，少量内容已保留在章节末尾" end
    return title .. "下载完成"
end

function Result.summary_note(record)
    local lines = {}
    if Result.annotation_pending(record) then
        lines[#lines + 1] = "正文已生成，部分划线或想法暂未取得，可稍后重新下载补全。"
    end
    if Result.annotation_fallback(record) then
        lines[#lines + 1] = "少量无法准确定位的内容已保留在对应章节末尾。"
    end
    return #lines > 0 and table.concat(lines, "\n") or nil
end

return Result
