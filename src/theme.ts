import { PlatformColor } from 'react-native';

export const colors = {
  background: PlatformColor('systemGroupedBackgroundColor'),
  surface: PlatformColor('secondarySystemGroupedBackgroundColor'),
  label: PlatformColor('labelColor'),
  secondaryLabel: PlatformColor('secondaryLabelColor'),
  separator: PlatformColor('separatorColor'),
  blue: PlatformColor('systemBlueColor'),
  red: PlatformColor('systemRedColor'),
  green: PlatformColor('systemGreenColor'),
  orange: PlatformColor('systemOrangeColor'),
} as const;

export const spacing = {
  x1: 4,
  x2: 8,
  x3: 12,
  x4: 16,
  x8: 32,
} as const;

export const radii = {
  card: 14,
  button: 12,
} as const;
