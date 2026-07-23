# 动作库与演示媒体生成

`PeakLog/Resources/` 下的动作库和演示动画不是手写的，由这里的脚本从
[hasaneyldrm/exercises-dataset](https://github.com/hasaneyldrm/exercises-dataset)
生成。改动作库时改这里的输入文件再重跑，不要直接编辑生成物。

## 授权（先看这一条）

- 动作**数据**（名称、分类、器械、分步说明）是 MIT。
- 动作**媒体**（缩略图和动画）版权属于 **Gym visual**，数据集仓库是拿到单独书面
  许可才转载的，其 `NOTICE.md` 明确写了 clone 仓库不等于获得授权。
- 因此 App 内必须保留 `© Gym visual — https://gymvisual.com/` 署名（详情页底部
  和「我的」页底部各一处），且媒体只能以 180×180 分发。
- 上架前需要自行向 Gym visual 确认许可。

## 输入

| 文件 | 作用 |
| --- | --- |
| `curated_seed.json` | 原有 135 个精选动作，**唯一事实来源**。手写中文名、别名、popularity 都在这里，生成时原样保留。 |
| `curated_media_map.json` | 这 135 个动作 → 数据集记录 id 的人工对照表。空字符串表示数据集里没有对得上的动作。 |
| `glossary.json` | 英文动作名 → 中文的短语/词条表，外加整名覆盖。1,300 多个新动作的中文名由它组合而来。 |

## 输出

| 文件 | 内容 | 大小 |
| --- | --- | --- |
| `PeakLog/Resources/exercise_library.json` | 搜索/列表索引，App 启动时加载 | ~355 KB |
| `PeakLog/Resources/exercise_details.json` | 分步说明与肌群，详情页首次打开时懒加载 | ~1.3 MB |
| `PeakLog/Resources/ExerciseMedia/<id>.mov` | HEVC 循环动画 | 共 ~16 MB |
| `PeakLog/Resources/ExerciseMedia/<id>.jpg` | 180×180 缩略图 | 共 ~8.5 MB |

源 GIF 合计 122.8 MB，转 HEVC 后约 16 MB（≈7.7×）。列表用 JPG 缩略图，详情页才
播 `.mov`，所以列表滚动不需要解码视频。

## 重跑

```bash
git clone --depth 1 https://github.com/hasaneyldrm/exercises-dataset.git /tmp/exercises-dataset
./tools/exercise-media/convert_all.sh /tmp/exercises-dataset PeakLog/Resources/ExerciseMedia 0.7
./tools/exercise-media/build_library.py /tmp/exercises-dataset .
```

`build_library.py` 是幂等的——它从 `curated_seed.json` 读精选动作，不读自己的输出，
所以重复跑结果一致。第三个参数是 HEVC 质量（0–1），0.7 在 180×180 上约 37 dB PSNR。

只想看精选动作的匹配情况而不写文件：

```bash
./tools/exercise-media/build_library.py /tmp/exercises-dataset . --review
```

## 验证

```bash
swiftc -O -o /tmp/exmedia_test tests/exercise_media_library_test.swift \
  PeakLog/Models/ExerciseLibraryModels.swift PeakLog/Models/TrainingPlanModels.swift \
  PeakLog/Models/WorkoutModels.swift PeakLog/Localization/AppLanguage.swift \
  PeakLog/Services/ExerciseMediaLibrary.swift && /tmp/exmedia_test
```

这个契约测试卡住的是重跑最容易破坏的东西：135 个精选 id 必须还在（训练历史按
`exerciseId` 引用它们）、精选动作的中文名/popularity 不能被改写、每个 `mediaId`
必须真的有对应的 `.mov` 和 `.jpg`、枚举取值必须是 Swift 侧解得出来的。

## 已知取舍

- 13 个精选动作在数据集里没有对得上的演示（臀推、面拉、V 字起、推雪橇等），
  `curated_media_map.json` 里留空，UI 回退到肌群图标。宁可没有动画也不要配错的
  ——自动匹配曾把「Plank」匹配到 `front plank with twist`（实际是侧平板）。
- 中文名是词典组合出来的，常见动作准确，长尾里偶有生硬的（如「哑铃仰卧旋前」）。
  要改单条就往 `glossary.json` 的 `name_overrides` 里加整名覆盖。
- 数据集里 29 条 cardio 记录中，纯有氧器械（跑步机、动感单车、椭圆机等）被排除，
  因为 App 用 `CardioActivityType` 单独按距离/时长记录；自重体能动作（波比跳、
  登山跑等）保留为 `full_body`。
