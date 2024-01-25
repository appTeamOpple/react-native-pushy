import React, {
  ReactNode,
  useCallback,
  useEffect,
  useRef,
  useState,
} from 'react';
import {
  Alert,
  NativeEventSubscription,
  AppState,
  Platform,
  Linking,
} from 'react-native';
import { Pushy } from './client';
import { currentVersion, isFirstTime, packageVersion } from './core';
import { CheckResult } from './type';
import { PushyContext } from './context';

export const PushyProvider = ({
  client,
  children,
}: {
  client: Pushy;
  children: ReactNode;
}) => {
  const { strategy, useAlert } = client.options;
  const stateListener = useRef<NativeEventSubscription>();
  const [updateInfo, setUpdateInfo] = useState<CheckResult>();
  const [lastError, setLastError] = useState<Error>();

  const dismissError = useCallback(() => {
    if (lastError) {
      setLastError(undefined);
    }
  }, [lastError]);

  const showAlert = useCallback(
    (...args: Parameters<typeof Alert.alert>) => {
      if (useAlert) {
        Alert.alert(...args);
      }
    },
    [useAlert],
  );

  const switchVersion = useCallback(() => {
    if (updateInfo && updateInfo.hash) {
      client.switchVersion(updateInfo.hash);
    }
  }, [client, updateInfo]);

  const switchVersionLater = useCallback(() => {
    if (updateInfo && updateInfo.hash) {
      client.switchVersionLater(updateInfo.hash);
    }
  }, [client, updateInfo]);

  const downloadUpdate = useCallback(async () => {
    if (!updateInfo || !updateInfo.update) {
      return;
    }
    try {
      const hash = await client.downloadUpdate(updateInfo);
      if (!hash) {
        return;
      }
      stateListener.current && stateListener.current.remove();
      showAlert('提示', '下载完毕，是否立即更新?', [
        {
          text: '下次再说',
          style: 'cancel',
          onPress: () => {
            client.switchVersionLater(hash);
          },
        },
        {
          text: '立即更新',
          style: 'default',
          onPress: () => {
            client.switchVersion(hash);
          },
        },
      ]);
    } catch (err) {
      setLastError(err);
      showAlert('更新失败', err.message);
    }
  }, [client, showAlert, updateInfo]);

  const checkUpdate = useCallback(async () => {
    let info: CheckResult;
    try {
      info = await client.checkUpdate();
    } catch (err) {
      setLastError(err);
      showAlert('更新检查失败', err.message);
      return;
    }
    setUpdateInfo(info);
    if (info.expired) {
      const { downloadUrl } = info;
      showAlert('提示', '您的应用版本已更新，点击更新下载安装新版本', [
        {
          text: '更新',
          onPress: () => {
            if (downloadUrl) {
              if (Platform.OS === 'android' && downloadUrl.endsWith('.apk')) {
                client.downloadAndInstallApk(downloadUrl);
              } else {
                Linking.openURL(downloadUrl);
              }
            }
          },
        },
      ]);
    } else if (info.update) {
      showAlert(
        '提示',
        '检查到新的版本' + info.name + ',是否下载?\n' + info.description,
        [
          { text: '取消', style: 'cancel' },
          {
            text: '确定',
            style: 'default',
            onPress: () => {
              downloadUpdate();
            },
          },
        ],
      );
    }
  }, [client, downloadUpdate, showAlert]);

  const markSuccess = client.markSuccess;

  useEffect(() => {
    if (isFirstTime) {
      markSuccess();
    }
    if (strategy === 'both' || strategy === 'onAppResume') {
      stateListener.current = AppState.addEventListener(
        'change',
        (nextAppState) => {
          if (nextAppState === 'active') {
            checkUpdate();
          }
        },
      );
    }
    if (strategy === 'both' || strategy === 'onAppStart') {
      checkUpdate();
    }
    let dismissErrorTimer: ReturnType<typeof setTimeout>;
    const { dismissErrorAfter } = client.options;
    if (typeof dismissErrorAfter === 'number' && dismissErrorAfter > 0) {
      dismissErrorTimer = setTimeout(() => {
        dismissError();
      }, dismissErrorAfter);
    }
    return () => {
      stateListener.current && stateListener.current.remove();
      clearTimeout(dismissErrorTimer);
    };
  }, [checkUpdate, client.options, dismissError, markSuccess, strategy]);

  return (
    <PushyContext.Provider
      value={{
        checkUpdate,
        switchVersion,
        switchVersionLater,
        dismissError,
        updateInfo,
        lastError,
        markSuccess,
        client,
        downloadUpdate,
        packageVersion,
        currentHash: currentVersion,
      }}
    >
      {children}
    </PushyContext.Provider>
  );
};
