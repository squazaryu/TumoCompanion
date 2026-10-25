import CoreGraphics

let cases: [(CGFloat, CGFloat)] = [
    (0, 108), (-1, 108), (.nan, 108), (.infinity, 108), (-.infinity, 108),
    (80, 108), (108, 108), (119.6667, 120), (132, 132), (180.2, 181),
]
for (controls, expected) in cases {
    let actual = ConsolePreviewMetrics.height(matchingControls: controls)
    precondition(actual == expected && actual.isFinite, "Preview must explicitly match finite controls height")
}
print("Console measured-height policy: \(cases.count) checks passed")
