import 'package:flutter/material.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关于', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 16),
            Text(
              'FaceSwap Studio 采用 Flutter 作为正式跨平台前端，'
              'FaceFusion 作为推理引擎，Python Bridge 作为中间适配层。',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 18),
            Text(
              '免责声明：本软件仅限合法、合规与经授权场景使用，不得用于侵犯他人肖像权、隐私权、著作权或任何非法用途，'
              '违者需自行承担全部法律责任。',
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: 18),
            const SelectableText('联系作者：QQ 419773176 / 微信 15085152352'),
            const Spacer(),
            Text(
              '当前阶段：Flutter Windows 桌面壳层骨架',
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
      ),
    );
  }
}
