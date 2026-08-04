local M = {}

M.MARKER_BEGIN = "/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */"
M.MARKER_END = "/* MIUREAD_ANNOTATION_STYLE_V2_END */"

-- Keep this intentionally close to the proven weread implementation.
-- The thought text uses its own class, so it can never inherit the solid
-- underline rule used by ordinary WeRead marks.
M.CSS = [[
/* MIUREAD_ANNOTATION_STYLE_V2_BEGIN */
.miu-inline-mark {
    text-decoration: underline;
}
.miu-thought-link {
    text-decoration: none;
    color: inherit;
}
.miu-thought-link .miu-thought-mark {
    color: inherit;
}
.miu-thought-mark {
    border-bottom: 2px dashed #ff6b35;
    padding-bottom: 2px;
}
.miu-thought-star {
    font-size: 0;
    line-height: 0;
    margin: 0;
    padding: 0;
    color: transparent;
}
/* MIUREAD_ANNOTATION_STYLE_V2_END */
]]

M.INLINE_STYLE_ID = "miuread-annotation-style"

function M.inline_style_tag()
    return '<style id="' .. M.INLINE_STYLE_ID .. '" type="text/css">\n'
        .. M.CSS
        .. '\n</style>'
end



-- MiuRead-generated style.css is a flat list of rules. Remove every previous
-- annotation rule completely, instead of appending a higher-specificity patch.
return M
