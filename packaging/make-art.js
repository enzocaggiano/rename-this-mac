// Draws the app icon and the DMG background as PNG files.
// Usage: osascript -l JavaScript make-art.js icon <out.png> <size>
//        osascript -l JavaScript make-art.js background <out.png> <scale>
ObjC.import('Cocoa');

function color(hex, a) {
  var n = parseInt(hex.slice(1), 16);
  return $.NSColor.colorWithSRGBRedGreenBlueAlpha(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, a === undefined ? 1 : a);
}

function canvas(w, h, draw, out) {
  var rep = $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(
    null, w, h, 8, 4, true, false, $.NSCalibratedRGBColorSpace, 0, 0);
  $.NSGraphicsContext.saveGraphicsState;
  $.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
  draw(w, h);
  $.NSGraphicsContext.currentContext.flushGraphics;
  $.NSGraphicsContext.restoreGraphicsState;
  rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({})).writeToFileAtomically(out, true);
}

function rrect(x, y, w, h, r) { return $.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius($.NSMakeRect(x, y, w, h), r, r); }

function text(str, x, y, size, hex, weight, centerWidth) {
  var font = $.NSFont.systemFontOfSizeWeight(size, weight);
  var attrs = $.NSDictionary.dictionaryWithObjectsForKeys(
    $([font, color(hex)]), $([$.NSFontAttributeName, $.NSForegroundColorAttributeName]));
  var s = $.NSString.alloc.initWithUTF8String(str);
  if (centerWidth) x = x + (centerWidth - s.sizeWithAttributes(attrs).width) / 2;
  s.drawAtPointWithAttributes($.NSMakePoint(x, y), attrs);
}

// 1024-unit icon grid: Apple's 824-unit rounded square, a Mac display, and a name tag.
function drawIcon(px) {
  var k = px / 1024;
  canvas(px, px, function () {
    var t = $.NSAffineTransform.transform;
    t.scaleBy(k); t.concat;

    var bg = rrect(100, 100, 824, 824, 185);
    $.NSGradient.alloc.initWithStartingColorEndingColor(color('#5B9BFF'), color('#1F4FC4')).drawInBezierPathAngle(bg, -90);

    color('#FFFFFF').setFill;
    rrect(232, 330, 560, 380, 40).fill;
    $.NSBezierPath.fillRect($.NSMakeRect(472, 262, 80, 72));
    rrect(392, 236, 240, 34, 17).fill;
    color('#163C99').setFill;
    rrect(262, 360, 500, 320, 18).fill;

    // name tag, tilted over the screen
    var tag = $.NSAffineTransform.transform;
    tag.translateXByYBy(512, 470); tag.rotateByDegrees(-8); tag.concat;
    color('#FFC83D').setFill;
    var body = $.NSBezierPath.bezierPath;
    body.moveToPoint($.NSMakePoint(-170, 70));
    body.lineToPoint($.NSMakePoint(170, 70));
    body.lineToPoint($.NSMakePoint(170, -70));
    body.lineToPoint($.NSMakePoint(-170, -70));
    body.lineToPoint($.NSMakePoint(-230, 0));
    body.closePath; body.fill;
    color('#163C99').setFill;
    $.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(-200, -14, 28, 28)).fill;
    text('Aa', -150, -52, 104, '#163C99', 0.62, 300);
  }, $.NSString.alloc.initWithUTF8String(OUT));
}

// DMG window background: 640x400 points, with a drag arrow between the two icon spots.
function drawBackground(scale) {
  canvas(640 * scale, 400 * scale, function () {
    var t = $.NSAffineTransform.transform; t.scaleBy(scale); t.concat;
    color('#F4F6FA').setFill; $.NSBezierPath.fillRect($.NSMakeRect(0, 0, 640, 400));
    color('#2F6BE0').setFill; color('#2F6BE0').setStroke;
    var shaft = $.NSBezierPath.bezierPath;
    shaft.moveToPoint($.NSMakePoint(250, 250)); shaft.lineToPoint($.NSMakePoint(372, 250));
    shaft.setLineWidth(8); shaft.setLineCapStyle(1); shaft.stroke;
    var head = $.NSBezierPath.bezierPath;
    head.moveToPoint($.NSMakePoint(398, 250)); head.lineToPoint($.NSMakePoint(366, 272)); head.lineToPoint($.NSMakePoint(366, 228));
    head.closePath; head.fill;
    text('Drag Rename this Mac to Applications', 0, 72, 17, '#1B2433', 0.3, 640);
    text('First open: if macOS blocks it, open System Settings → Privacy & Security → Open Anyway.', 0, 44, 12, '#5A6577', 0, 640);
  }, $.NSString.alloc.initWithUTF8String(OUT));
}

var OUT;
function run(argv) {
  OUT = argv[1];
  if (argv[0] === 'icon') drawIcon(parseInt(argv[2] || '1024', 10));
  else drawBackground(parseInt(argv[2] || '1', 10));
  return OUT;
}
