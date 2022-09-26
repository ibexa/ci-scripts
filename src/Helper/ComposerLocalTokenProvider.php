<?php

/**
 * @copyright Copyright (C) Ibexa AS. All rights reserved.
 * @license For full copyright and license information view LICENSE file distributed with this source code.
 */
declare(strict_types=1);

namespace Ibexa\ContiniousIntegrationScripts\Helper;

class ComposerLocalTokenProvider
{
    public function getGitHubToken(): ?string
    {
        $output = [];
        $resultCode = 0;
        exec('composer config github-oauth.github.com --global 2> /dev/null', $output, $resultCode);

        return $resultCode === 0 ? $output[0] : null;
    }
}
