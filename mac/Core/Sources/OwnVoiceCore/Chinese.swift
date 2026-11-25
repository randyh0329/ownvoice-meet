// The captions' Chinese is the one the user chose: Traditional as used in Taiwan, or Simplified.
// The prompt asks for it, yet a model now and then answers a whole line in the other script; such a
// line goes through the system's transform. Traditional text is never converted to Traditional
// again: only the lines that read as Simplified are (several characters only Simplified Chinese
// uses, or a fair share of a short line), so one character that Taiwan also writes cannot turn
// 范 into 範 or 干擾 into 乾擾 elsewhere. Converting to Simplified leaves Simplified text as it is.

import Foundation

public enum ChineseVariant: String, CaseIterable, Codable, Identifiable, Sendable {
    case traditionalTaiwan = "zh-TW"
    case simplified = "zh-CN"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .traditionalTaiwan: "繁體中文（台灣）"
        case .simplified: "简体中文"
        }
    }

    /// How the prompts name it.
    var promptName: String {
        switch self {
        case .traditionalTaiwan: "Traditional Chinese as used in Taiwan"
        case .simplified: "Simplified Chinese as used in mainland China"
        }
    }

    var promptTag: String {
        switch self {
        case .traditionalTaiwan: "繁體中文"
        case .simplified: "简体中文"
        }
    }

    var scriptName: String {
        switch self {
        case .traditionalTaiwan: "Traditional Chinese"
        case .simplified: "Simplified Chinese"
        }
    }

    /// Apple Translation targets to try, most specific first.
    public var appleTargets: [String] {
        switch self {
        case .traditionalTaiwan: ["zh-Hant-TW", "zh-TW", "zh-Hant"]
        case .simplified: ["zh-Hans-CN", "zh-CN", "zh-Hans"]
        }
    }

    /// The text in this variant's script.
    public func fix(_ text: String) -> String {
        switch self {
        case .traditionalTaiwan:
            return ChineseScript.lines(text).map { line in
                guard ChineseScript.isSimplified(line) else { return line }
                return line.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? line
            }.joined()
        case .simplified:
            // Anything Traditional becomes Simplified; Simplified characters pass through unchanged.
            return text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        }
    }
}

public enum ChineseScript {
    /// Common characters that exist only in Simplified Chinese. Characters that ordinary Taiwan
    /// text also uses are left out: 佣 (佣金), 涂 (a surname), 夸 (夸克), 据 (拮据), 霉 (發霉),
    /// 划 (划算), 丰, 庄, 坛, 彦.
    static let simplifiedOnly = Set("这们说为个会时对没过还现问题发经实样关见进开动学长给让认话应该机点从两车东间头边门马无变当岁网视频讲读写际复谈坏块组赖规务击类专业乐买卖气电书钱钟铁银错锁种丢严临举义乌习乡亚产亲仅众优伟传伤伦体侠侣侦侧侨俭债倾偿储儿兑兰兴养兽内册军农决况冻净凉减凤凭则刚创删别剧劝办劳势勋区医华协单卢卫却厂厅历压厌县参双叙号叹吓吗吨听启吴呐员呜咏响哑唤啰啸喷团园围图圆圣场坚坝坟坠垄垦垫埘壮声壳处备夹夺奋奖妇妈娱娲娴婴宁宝宠审宪宫宽宾寻导将尔尘尝层属岂岗岛岭峡币师帅帐带帮帧帼广庆库庙庞废异弃张弥弯弹强归录彻径忆忧怀态怜总恋恳恶悬惊惯愤愿戏战户执扩扫扬扰抚抛抢护报担拟拥择挂挡挣挤挥损换掳掷揽搀搁携摄摆摇摊撑撵擞攒敌数斋旧旷昙显晋晒晓晕暂术杀杂权条来杨极构枪枫柜标栈栋栏树桥档梦检棱椭横欢欧歼毁毕毙汇汉汤沟沥沦沧沪泪泷泸泽洁洒浅浆浇浊测济浏浑浓涛涝涡润涧涨涩渊渐渔渗温湾湿溃溅滚满滤滥滨滩潆灭灯灵灾灿炉炼烁烂热焕爱爷牵犹狈狮独狭猎猪献环玛玮珐琐琼瑶瓒画畅畴疗疟疮疯痒瘫癣皑盏盐监盖盘睁矫矿码砖础硕确碍礼祸祯离秃秆积称稳穷窃窍窑窜窝竖竞笔笼筛筝签简箩篮篱粮紧纠红纤约级纪纫纬纯纱纲纳纵纷纸纹纺线练细织终绍结绕绘络绝绞统绢绣继绩绪续绰绳维绵综绿缀缓编缘缠缩缴罗罚罢羡翘耸联聪肃肠肤肾肿胀胁胆胶脉脏脑脚脱脸舰舱艰艳节芜苇苍苏茎荐荚荡荣药莱莲获莹萤营萧萨蓝蔼虏虑虚虽蚀蚁蚂蛮蜗蝇补衬袄袜装裤观览觉触誉计订讥讨训议讯记讳讶许论讼设访证评识诈诉诊词译试诗诚诞询详语误诱请诸诺课谁调谅谊谋谍谎谐谓谜谢谣谦谨谱贝贞负贡财责贤败账货质贩贪贫贬购贮贯贱贴贵贷贸费贺贼资赋赌赏赐赔赚赛赞赠赵赶趋跃践踪轨轩转轮软轰轴轻载较辅辆辈辉辑输辖辩辫辽达迁迈运远违连迟选逊递逻遗邓邮邻郑酝酱酿释钉针钓钙钢钥钦钩钮钳铃铅铜铭铲铸铺链销锅锋锡锣锤锦键锯锻镇镜闪闭闯闲闷闸闹闻阀阁阅队阳阴阵阶陆陈陕险随隐隶难雏雾静鞑韦韧韩页顶项顺须顽顾顿颁预领颗颜额风飘飞饥饭饮饰饱饲饼饿馆馈驱驳驶驻驾骂骄骆验骑骗骤鱼鲁鲜鸟鸡鸣鸭鸽鹅鹰麦黄齐齿龙龟")

    /// Whether `text` reads as Simplified Chinese: at least two characters only Simplified Chinese
    /// uses, or one that makes up a tenth or more of its Chinese characters (a short line).
    public static func isSimplified(_ text: String) -> Bool {
        var hits = 0
        var han = 0
        for c in text {
            if simplifiedOnly.contains(c) { hits += 1 }
            if isHan(c) { han += 1 }
            if hits >= 2 { return true }
        }
        return hits == 1 && han <= 10
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x20000...0x3FFFF).contains($0.value) }
    }

    /// The lines of `text`, each with its line break, so that joining them gives `text` back.
    static func lines(_ text: String) -> [String] {
        var out: [String] = []
        var line = ""
        for c in text {
            line.append(c)
            if c.isNewline {
                out.append(line)
                line = ""
            }
        }
        if !line.isEmpty || out.isEmpty { out.append(line) }
        return out
    }
}
