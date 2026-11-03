@{
    # 只把 Error 与 Warning 视为需要处理的问题；Information 级别的建议不阻断构建。
    Severity = @('Error', 'Warning')

    # 以下规则对「面向终端的安装器 CLI」属于有意豁免：
    #   PSAvoidUsingWriteHost                              —— 菜单与进度直接输出到控制台，不使用 Write-Output 污染管道
    #   PSUseSingularNouns                                 —— 多个函数返回集合（组件、安装包、语言），名称保留复数更直观
    #   PSUseShouldProcessForStateChangingFunctions        —— 安装动作本身已由 -WhatIf 与显式确认控制，函数级 ShouldProcess 会重复询问
    #   PSAvoidUsingPositionalParameters                   —— 内部调用统一使用命名参数；该规则会对第三方模块调用误报
    #   PSUseSupportsShouldProcess                         —— 工具自行实现 -WhatIf 预览语义并向下传递，改用 SupportsShouldProcess 会改变现有命令行行为
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseSingularNouns'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingPositionalParameters'
        'PSUseSupportsShouldProcess'
    )
}
