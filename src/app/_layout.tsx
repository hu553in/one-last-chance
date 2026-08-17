import { DarkTheme, DefaultTheme, Link, Stack, ThemeProvider } from 'expo-router';
import { SymbolView } from 'expo-symbols';
import { Pressable, useColorScheme } from 'react-native';

import { colors } from '@/theme';

export default function RootLayout() {
  const scheme = useColorScheme();

  return (
    <ThemeProvider value={scheme === 'dark' ? DarkTheme : DefaultTheme}>
      <Stack
        screenOptions={{
          contentStyle: { backgroundColor: colors.background },
          headerBackButtonDisplayMode: 'minimal',
          headerShadowVisible: false,
        }}
      >
        <Stack.Screen
          name="index"
          options={{
            title: 'One Last Chance',
            headerLargeTitle: true,
            headerRight: () => (
              <Link href="/logs" asChild>
                <Pressable accessibilityLabel="Open logs" hitSlop={12}>
                  {({ pressed }) => (
                    <SymbolView
                      name="doc.text.magnifyingglass"
                      size={21}
                      tintColor={colors.blue}
                      style={{ opacity: pressed ? 0.45 : 1 }}
                    />
                  )}
                </Pressable>
              </Link>
            ),
          }}
        />
        <Stack.Screen name="logs" options={{ title: 'Logs' }} />
      </Stack>
    </ThemeProvider>
  );
}
